// Same as policies_members_or_public.cedar, but expressed as two rules
permit(principal, action == Action::"readProject", resource)
when { principal in resource.team };

permit(principal, action == Action::"readProject", resource)
when { !resource.internal };
