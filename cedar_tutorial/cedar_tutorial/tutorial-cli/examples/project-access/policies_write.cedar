// Only team members may write
permit(principal, action == Action::"writeProject", resource)
when { principal in resource.team };
