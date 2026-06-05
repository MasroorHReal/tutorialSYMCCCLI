// Approve expenses over $10,000 (any employee — for testing disjoint)
permit(principal, action == Action::"approveExpense", resource)
when { resource.amount > 10000 };
