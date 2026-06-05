permit(principal, action == Action::"view", resource)
when { resource.owner == principal };
