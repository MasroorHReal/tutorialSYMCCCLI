// Only approve expenses from employees in your own department
permit(principal, action == Action::"approveExpense", resource)
when { principal.department == resource.submitter.department };
