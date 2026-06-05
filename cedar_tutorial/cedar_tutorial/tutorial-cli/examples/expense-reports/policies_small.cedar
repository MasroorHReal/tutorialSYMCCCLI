// Approve expenses under $1,000 (any employee)
permit(principal, action == Action::"approveExpense", resource)
when { resource.amount < 1000 };
