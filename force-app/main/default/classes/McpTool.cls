/**
 * MCP 서버가 외부 AI 에 노출하는 도구 하나.
 * 도구를 추가하려면 이 인터페이스를 구현하고 McpToolRegistry 에 등록한다.
 */
public interface McpTool {
    String name();
    String description();
    /** 인자 JSON Schema (MCP tools/list 의 inputSchema) */
    Map<String, Object> inputSchema();
    /** 실행 결과 텍스트. 인자가 잘못되면 McpServer.McpException(INVALID_PARAMS) 을 던진다. */
    String call(Map<String, Object> arguments);
}
