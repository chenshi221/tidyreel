// Zero-cost typed ids so a TaskId can never be passed where a GroupId is expected.

extension type const ConnectionId(String value) {}

extension type const TaskId(String value) {}

extension type const GroupId(String value) {}

extension type const OpId(String value) {}

extension type const BatchId(String value) {}
