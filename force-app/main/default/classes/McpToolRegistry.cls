/**
 * 서버가 제공하는 도구 목록. 순서가 tools/list 응답 순서가 된다.
 */
public with sharing class McpToolRegistry {

    public static List<McpTool> all() {
        return new List<McpTool>{ new AccountSearchTool(), new CreateFollowUpTaskTool() };
    }

    public static McpTool find(String name) {
        for (McpTool tool : all()) {
            if (tool.name() == name) {
                return tool;
            }
        }
        return null;
    }
}
