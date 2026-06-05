// v2: buggy refactor — AND instead of OR, accidentally makes policy more restrictive
permit(principal, action == Action::"viewAlbum", resource)
when { resource.public && resource.owner == principal };
