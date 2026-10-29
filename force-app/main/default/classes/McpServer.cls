/**
 * Apex REST 로 구현한 최소 MCP 서버 (Streamable HTTP, JSON 응답 모드).
 *
 * POST /services/apexrest/mcp      JSON-RPC 2.0 요청 (단건 또는 묶음)
 * GET  /services/apexrest/mcp/prm  OAuth 보호 리소스 메타데이터 (RFC 9728)
 *
 * 지원 메서드: initialize, ping, notifications/*, tools/list, tools/call
 * 인증되지 않은 요청(사이트 게스트)은 401 과 WWW-Authenticate 헤더로 OAuth 탐색 위치를 알려 준다.
 * 인가 서버는 이 org 의 My Domain 이므로 별도 인증 서버가 필요 없다.
 */
@RestResource(urlMapping='/mcp/*')
global with sharing class McpServer {

    public class McpException extends Exception {
        public Integer code;
        public McpException(Integer code, String message) {
            this(message);
            this.code = code;
        }
    }

    public static final Integer PARSE_ERROR = -32700;
    public static final Integer INVALID_REQUEST = -32600;
    public static final Integer METHOD_NOT_FOUND = -32601;
    public static final Integer INVALID_PARAMS = -32602;
    public static final Integer INTERNAL_ERROR = -32603;

    private static final String JSONRPC_VERSION = '2.0';
    private static final List<String> SUPPORTED_PROTOCOLS = new List<String>{ '2025-06-18', '2025-03-26' };
    private static final String DEFAULT_PROTOCOL = '2025-06-18';
    private static final String SERVER_NAME = 'salesforce-mcp-demo';
    private static final String SERVER_VERSION = '1.0.0';
    private static final String REST_PATH = '/services/apexrest/mcp';
    private static final String METADATA_SUFFIX = '/prm';

    @TestVisible
    private static Boolean forceGuestForTest = false;

    @HttpPost
    global static void handlePost() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json; charset=utf-8');
        if (isGuest()) {
            writeUnauthorized(response);
            return;
        }

        Object parsed;
        try {
            Blob body = RestContext.request.requestBody;
            parsed = JSON.deserializeUntyped(body == null ? '' : body.toString());
        } catch (Exception e) {
            writeJson(response, 400, error(null, PARSE_ERROR, 'Request body must be valid JSON.'));
            return;
        }

        Object reply;
        if (parsed instanceof List<Object>) {
            List<Object> replies = new List<Object>();
            for (Object message : (List<Object>) parsed) {
                Map<String, Object> single = handleMessage(message);
                if (single != null) {
                    replies.add(single);
                }
            }
            reply = replies.isEmpty() ? null : replies;
        } else {
            reply = handleMessage(parsed);
        }

        if (reply == null) {
            // 알림만 받았으면 돌려줄 내용이 없다.
            response.statusCode = 202;
            return;
        }
        writeJson(response, 200, reply);
    }

    @HttpGet
    global static void handleGet() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json; charset=utf-8');
        String uri = RestContext.request.requestURI;
        if (uri != null && uri.endsWith(METADATA_SUFFIX)) {
            writeJson(response, 200, protectedResourceMetadata());
            return;
        }
        if (isGuest()) {
            writeUnauthorized(response);
            return;
        }
        // 서버에서 클라이언트로 보내는 SSE 스트림은 지원하지 않는다 (규격상 405 허용).
        response.statusCode = 405;
    }

    /**
     * JSON-RPC 메시지 하나를 처리한다. 응답이 필요 없는 알림이면 null.
     */
    @TestVisible
    private static Map<String, Object> handleMessage(Object raw) {
        if (!(raw instanceof Map<String, Object>)) {
            return error(null, INVALID_REQUEST, 'Message must be a JSON object.');
        }
        Map<String, Object> message = (Map<String, Object>) raw;
        Object id = message.get('id');
        Boolean isNotification = !message.containsKey('id');
        String method = (String) message.get('method');
        if (method == null) {
            // 클라이언트가 보낸 응답 메시지. 이 서버는 요청을 보내지 않으므로 무시한다.
            return null;
        }
        Map<String, Object> params = message.get('params') instanceof Map<String, Object>
            ? (Map<String, Object>) message.get('params')
            : new Map<String, Object>();

        try {
            Object result = dispatch(method, params);
            return isNotification ? null : new Map<String, Object>{
                'jsonrpc' => JSONRPC_VERSION, 'id' => id, 'result' => result
            };
        } catch (McpException e) {
            return isNotification ? null : error(id, e.code, e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[McpServer.handleMessage] ' + e.getMessage() + '\n' + e.getStackTraceString());
            return isNotification ? null : error(id, INTERNAL_ERROR, 'Internal error (' + e.getTypeName() + ').');
        }
    }

    private static Object dispatch(String method, Map<String, Object> params) {
        if (method == 'initialize') {
            return initialize(params);
        }
        if (method == 'ping' || method.startsWith('notifications/')) {
            return new Map<String, Object>();
        }
        if (method == 'tools/list') {
            return new Map<String, Object>{ 'tools' => listTools() };
        }
        if (method == 'tools/call') {
            return callTool(params);
        }
        throw new McpException(METHOD_NOT_FOUND, 'Method not found: ' + method);
    }

    private static Map<String, Object> initialize(Map<String, Object> params) {
        String requested = (String) params.get('protocolVersion');
        return new Map<String, Object>{
            'protocolVersion' => SUPPORTED_PROTOCOLS.contains(requested) ? requested : DEFAULT_PROTOCOL,
            'capabilities' => new Map<String, Object>{ 'tools' => new Map<String, Object>{ 'listChanged' => false } },
            'serverInfo' => new Map<String, Object>{ 'name' => SERVER_NAME, 'version' => SERVER_VERSION },
            'instructions' => 'Write tools run in two steps: call with confirmed=false to get a summary, '
                + 'ask the user, then call again with confirmed=true.'
        };
    }

    private static List<Object> listTools() {
        List<Object> tools = new List<Object>();
        for (McpTool tool : McpToolRegistry.all()) {
            tools.add(new Map<String, Object>{
                'name' => tool.name(),
                'description' => tool.description(),
                'inputSchema' => tool.inputSchema()
            });
        }
        return tools;
    }

    private static Map<String, Object> callTool(Map<String, Object> params) {
        String name = (String) params.get('name');
        McpTool tool = McpToolRegistry.find(name);
        if (tool == null) {
            throw new McpException(INVALID_PARAMS, 'Unknown tool: ' + name);
        }
        Map<String, Object> arguments = params.get('arguments') instanceof Map<String, Object>
            ? (Map<String, Object>) params.get('arguments')
            : new Map<String, Object>();
        try {
            return toolResult(tool.call(arguments), false);
        } catch (McpException e) {
            // 인자 오류는 도구 결과의 isError 로 돌려줘서 AI 가 고쳐서 다시 부를 수 있게 한다.
            return toolResult(e.getMessage(), true);
        }
    }

    private static Map<String, Object> toolResult(String text, Boolean isError) {
        return new Map<String, Object>{
            'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => text } },
            'isError' => isError
        };
    }

    private static Map<String, Object> error(Object id, Integer code, String message) {
        return new Map<String, Object>{
            'jsonrpc' => JSONRPC_VERSION,
            'id' => id,
            'error' => new Map<String, Object>{ 'code' => code, 'message' => message }
        };
    }

    private static Boolean isGuest() {
        return forceGuestForTest || UserInfo.getUserType() == 'Guest';
    }

    private static void writeUnauthorized(RestResponse response) {
        response.statusCode = 401;
        response.addHeader('WWW-Authenticate', 'Bearer resource_metadata="' + serverUrl() + METADATA_SUFFIX + '"');
        response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'error' => 'invalid_token' }));
    }

    /** RFC 9728: 이 리소스의 인가 서버는 org 의 My Domain 이다. */
    @TestVisible
    private static Map<String, Object> protectedResourceMetadata() {
        return new Map<String, Object>{
            'resource' => serverUrl(),
            'authorization_servers' => new List<String>{ URL.getOrgDomainUrl().toExternalForm() },
            'scopes_supported' => new List<String>{ 'api', 'refresh_token' },
            'bearer_methods_supported' => new List<String>{ 'header' }
        };
    }

    private static String serverUrl() {
        String siteBase = Site.getBaseSecureUrl();
        String base = String.isNotBlank(siteBase) ? siteBase : URL.getOrgDomainUrl().toExternalForm();
        return base.removeEnd('/') + REST_PATH;
    }

    private static void writeJson(RestResponse response, Integer statusCode, Object payload) {
        response.statusCode = statusCode;
        response.responseBody = Blob.valueOf(JSON.serialize(payload));
    }
}
