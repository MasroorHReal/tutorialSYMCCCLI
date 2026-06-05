// Team members may read; anyone may read a non-internal project
permit(principal, action == Action::"readProject", resource)
when { principal in resource.team || !resource.internal };
