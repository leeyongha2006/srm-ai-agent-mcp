@IsTest
private class McpServer_Test {

    @TestSetup
    static void setup() {
        insert new List<Account>{
            new Account(Name = 'Acme Motors', Industry = 'Manufacturing'),
            new Account(Name = 'Acme Parts'),
            new Account(Name = 'Globex')
        };
    }

    private static RestResponse post(String body) {
        RestContext.request = new RestRequest();
        RestContext.request.requestURI = '/services/apexrest/mcp';
        RestContext.request.httpMethod = 'POST';
        RestContext.request.requestBody = body == null ? null : Blob.valueOf(body);
        RestContext.response = new RestResponse();
        McpServer.handlePost();
        return RestContext.response;
    }

    private static Map<String, Object> postJson(String body) {
        RestResponse response = post(body);
        Assert.areEqual(200, response.statusCode);
        return (Map<String, Object>) JSON.deserializeUntyped(response.responseBody.toString());
    }

    private static String rpc(Object id, String method, String paramsJson) {
        return '{"jsonrpc":"2.0","id":' + JSON.serialize(id) + ',"method":"' + method + '"'
            + (paramsJson == null ? '' : ',"params":' + paramsJson) + '}';
    }

    private static String toolText(Map<String, Object> reply) {
        Map<String, Object> result = (Map<String, Object>) reply.get('result');
        Map<String, Object> content = (Map<String, Object>) ((List<Object>) result.get('content'))[0];
        return (String) content.get('text');
    }

    @IsTest
    static void initializeNegotiatesProtocol() {
        Map<String, Object> result = (Map<String, Object>) postJson(rpc(1, 'initialize', '{"protocolVersion":"2025-03-26"}')).get('result');
        Assert.areEqual('2025-03-26', result.get('protocolVersion'));

        Map<String, Object> fallback = (Map<String, Object>) postJson(rpc(2, 'initialize', '{"protocolVersion":"1999-01-01"}')).get('result');
        Assert.areEqual('2025-06-18', fallback.get('protocolVersion'));
        Assert.isNotNull(fallback.get('serverInfo'));
    }

    @IsTest
    static void listsRegisteredTools() {
        Map<String, Object> result = (Map<String, Object>) postJson(rpc(1, 'tools/list', null)).get('result');
        List<Object> tools = (List<Object>) result.get('tools');
        Assert.areEqual(2, tools.size());
        Assert.areEqual('search_accounts', ((Map<String, Object>) tools[0]).get('name'));
        Assert.isNotNull(((Map<String, Object>) tools[0]).get('inputSchema'));
    }

    @IsTest
    static void searchToolReturnsMatchingAccounts() {
        Map<String, Object> reply = postJson(rpc(7, 'tools/call', '{"name":"search_accounts","arguments":{"keyword":"Acme"}}'));
        Assert.areEqual(7, reply.get('id'));
        List<Object> rows = (List<Object>) JSON.deserializeUntyped(toolText(reply));
        Assert.areEqual(2, rows.size());
    }

    @IsTest
    static void invalidToolArgumentsComeBackAsToolError() {
        Map<String, Object> reply = postJson(rpc(1, 'tools/call', '{"name":"search_accounts","arguments":{"keyword":"A"}}'));
        Map<String, Object> result = (Map<String, Object>) reply.get('result');
        Assert.areEqual(true, result.get('isError'));
    }

    @IsTest
    static void writeToolNeedsConfirmation() {
        Account account = [SELECT Id FROM Account WHERE Name = 'Globex' LIMIT 1];
        String args = '{"accountId":"' + account.Id + '","subject":"Send quote","dueDate":"2026-12-01"';

        String preview = toolText(postJson(rpc(1, 'tools/call', '{"name":"create_follow_up_task","arguments":' + args + ',"confirmed":false}}')));
        Assert.isTrue(preview.startsWith('Not created yet'));
        Assert.areEqual(0, [SELECT COUNT() FROM Task]);

        String created = toolText(postJson(rpc(2, 'tools/call', '{"name":"create_follow_up_task","arguments":' + args + ',"confirmed":true}}')));
        Assert.isTrue(created.startsWith('Created'));
        Task task = [SELECT Subject, ActivityDate, WhatId FROM Task LIMIT 1];
        Assert.areEqual('Send quote', task.Subject);
        Assert.areEqual(Date.newInstance(2026, 12, 1), task.ActivityDate);
        Assert.areEqual(account.Id, task.WhatId);
    }

    @IsTest
    static void writeToolRejectsBadInput() {
        Map<String, Object> badId = (Map<String, Object>) postJson(rpc(1, 'tools/call',
            '{"name":"create_follow_up_task","arguments":{"accountId":"nope","subject":"x","confirmed":true}}')).get('result');
        Assert.areEqual(true, badId.get('isError'));

        Account account = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> badDate = (Map<String, Object>) postJson(rpc(2, 'tools/call',
            '{"name":"create_follow_up_task","arguments":{"accountId":"' + account.Id + '","subject":"x","dueDate":"12/01","confirmed":true}}')).get('result');
        Assert.areEqual(true, badDate.get('isError'));
        Assert.areEqual(0, [SELECT COUNT() FROM Task]);
    }

    @IsTest
    static void unknownMethodAndToolReturnErrors() {
        Map<String, Object> method = (Map<String, Object>) postJson(rpc(1, 'resources/list', null)).get('error');
        Assert.areEqual(McpServer.METHOD_NOT_FOUND, method.get('code'));

        Map<String, Object> tool = (Map<String, Object>) postJson(rpc(2, 'tools/call', '{"name":"drop_tables"}')).get('error');
        Assert.areEqual(McpServer.INVALID_PARAMS, tool.get('code'));
    }

    @IsTest
    static void notificationsGet202AndBatchesSkipThem() {
        RestResponse notification = post('{"jsonrpc":"2.0","method":"notifications/initialized"}');
        Assert.areEqual(202, notification.statusCode);

        RestResponse batch = post('[' + rpc(1, 'ping', null) + ',{"jsonrpc":"2.0","method":"notifications/initialized"}]');
        List<Object> replies = (List<Object>) JSON.deserializeUntyped(batch.responseBody.toString());
        Assert.areEqual(1, replies.size());
    }

    @IsTest
    static void rejectsInvalidJsonAndNonObjects() {
        RestResponse invalid = post('{not json');
        Assert.areEqual(400, invalid.statusCode);

        Map<String, Object> notObject = (Map<String, Object>) postJson('"hello"').get('error');
        Assert.areEqual(McpServer.INVALID_REQUEST, notObject.get('code'));
    }

    @IsTest
    static void guestsGetOAuthDiscoveryHints() {
        McpServer.forceGuestForTest = true;
        RestResponse response = post(rpc(1, 'ping', null));
        Assert.areEqual(401, response.statusCode);
        Assert.isTrue(response.headers.get('WWW-Authenticate').contains('resource_metadata='));

        RestContext.request = new RestRequest();
        RestContext.request.requestURI = '/services/apexrest/mcp/prm';
        RestContext.response = new RestResponse();
        McpServer.handleGet();
        Map<String, Object> metadata = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.isFalse(((List<Object>) metadata.get('authorization_servers')).isEmpty());
    }

    @IsTest
    static void getWithoutStreamReturns405() {
        RestContext.request = new RestRequest();
        RestContext.request.requestURI = '/services/apexrest/mcp';
        RestContext.response = new RestResponse();
        McpServer.handleGet();
        Assert.areEqual(405, RestContext.response.statusCode);
    }
}
