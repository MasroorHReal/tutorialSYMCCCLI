// v3: correct rewrite — same logic as v1 with operands flipped
permit(principal, action == Action::"viewAlbum", resource)
when { resource.owner == principal || resource.public };
