/**
 * 읽기 도구 예: 이름으로 거래처를 찾는다.
 * 실행한 사용자의 권한(USER_MODE)으로 조회하므로 AI 가 볼 수 없는 데이터는 나오지 않는다.
 */
public with sharing class AccountSearchTool implements McpTool {

    private static final Integer MAX_RESULTS = 10;

    public String name() {
        return 'search_accounts';
    }

    public String description() {
        return 'Find accounts whose name contains the keyword. Returns up to ' + MAX_RESULTS + ' rows.';
    }

    public Map<String, Object> inputSchema() {
        return new Map<String, Object>{
            'type' => 'object',
            'properties' => new Map<String, Object>{
                'keyword' => new Map<String, Object>{ 'type' => 'string', 'description' => 'Part of the account name' }
            },
            'required' => new List<String>{ 'keyword' }
        };
    }

    public String call(Map<String, Object> arguments) {
        String keyword = arguments.get('keyword') == null ? '' : String.valueOf(arguments.get('keyword')).trim();
        if (keyword.length() < 2) {
            throw new McpServer.McpException(McpServer.INVALID_PARAMS, 'keyword must be at least 2 characters.');
        }
        String pattern = '%' + String.escapeSingleQuotes(keyword) + '%';
        List<Account> accounts = [
            SELECT Id, Name, Industry, AnnualRevenue
            FROM Account
            WHERE Name LIKE :pattern
            WITH USER_MODE
            ORDER BY Name
            LIMIT :MAX_RESULTS
        ];
        if (accounts.isEmpty()) {
            return 'No accounts found for "' + keyword + '".';
        }
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Account account : accounts) {
            rows.add(new Map<String, Object>{
                'id' => account.Id,
                'name' => account.Name,
                'industry' => account.Industry,
                'annualRevenue' => account.AnnualRevenue
            });
        }
        return JSON.serialize(rows);
    }
}
