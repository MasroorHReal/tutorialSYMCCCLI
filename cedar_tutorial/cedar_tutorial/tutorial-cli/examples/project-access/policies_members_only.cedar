// Only team members may read the project
permit(principal, action == Action::"readProject", resource)
when { principal in resource.team };
