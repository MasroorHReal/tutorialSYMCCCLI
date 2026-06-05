permit(principal, action == Action::"view", resource)
when { resource.owner == principal && context.count + context.limit > 0 };
