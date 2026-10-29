/**
 * 쓰기 도구 예: 거래처에 후속 작업(Task)을 만든다.
 *
 * AI 가 바로 데이터를 바꾸지 않도록 두 단계로 동작한다.
 * 1) confirmed=false → 무엇이 만들어지는지 요약만 돌려준다.
 * 2) 사용자가 동의하면 confirmed=true 로 다시 불러 실제로 만든다.
 */
public with sharing class CreateFollowUpTaskTool implements McpTool {

    public String name() {
        return 'create_follow_up_task';
    }

    public String description() {
        return 'Create a follow-up task on an account. Call with confirmed=false first, show the summary to the user, '
            + 'and call again with confirmed=true only after the user agrees.';
    }

    public Map<String, Object> inputSchema() {
        return new Map<String, Object>{
            'type' => 'object',
            'properties' => new Map<String, Object>{
                'accountId' => new Map<String, Object>{ 'type' => 'string' },
                'subject' => new Map<String, Object>{ 'type' => 'string' },
                'dueDate' => new Map<String, Object>{ 'type' => 'string', 'description' => 'YYYY-MM-DD' },
                'confirmed' => new Map<String, Object>{ 'type' => 'boolean' }
            },
            'required' => new List<String>{ 'accountId', 'subject', 'confirmed' }
        };
    }

    public String call(Map<String, Object> arguments) {
        Account account = findAccount((String) arguments.get('accountId'));
        String subject = arguments.get('subject') == null ? '' : String.valueOf(arguments.get('subject')).trim();
        if (String.isBlank(subject)) {
            throw new McpServer.McpException(McpServer.INVALID_PARAMS, 'subject is required.');
        }
        Date dueDate = parseDate((String) arguments.get('dueDate'));

        String summary = 'Task "' + subject + '" on ' + account.Name
            + (dueDate == null ? '' : ' due ' + String.valueOf(dueDate));
        if (arguments.get('confirmed') != true) {
            return 'Not created yet. Ask the user to confirm: ' + summary;
        }

        Task task = new Task(WhatId = account.Id, Subject = subject, ActivityDate = dueDate, Status = 'Not Started');
        Database.insert(task, AccessLevel.USER_MODE);
        return 'Created ' + summary + ' (Id ' + task.Id + ').';
    }

    private static Account findAccount(String accountId) {
        Id parsedId;
        try {
            parsedId = Id.valueOf(accountId);
        } catch (Exception e) {
            throw new McpServer.McpException(McpServer.INVALID_PARAMS, 'accountId is not a valid Id.');
        }
        List<Account> accounts = [SELECT Id, Name FROM Account WHERE Id = :parsedId WITH USER_MODE LIMIT 1];
        if (accounts.isEmpty()) {
            throw new McpServer.McpException(McpServer.INVALID_PARAMS, 'Account not found or not accessible.');
        }
        return accounts[0];
    }

    private static Date parseDate(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Date.valueOf(value);
        } catch (Exception e) {
            throw new McpServer.McpException(McpServer.INVALID_PARAMS, 'dueDate must be YYYY-MM-DD.');
        }
    }
}
