// v1: correct policy — view if public OR owner
permit(principal, action == Action::"viewAlbum", resource)
when { resource.public || resource.owner == principal };
