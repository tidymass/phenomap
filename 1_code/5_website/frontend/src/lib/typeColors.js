// Entity-type accent colors shared across the Entity Search page, the
// Entity Detail page (header accent, neighbor badges, neighbor network
// graph), and the Path Query page's connection graph -- kept in one place
// so a node's color reads the same everywhere it appears, and so adding a
// new label only means updating this one map instead of every view that
// happens to render a colored node or badge.
export const typeColors = { Study: '#3949ab', Phenotype: '#b3562c', Module: '#1a8f5e', Metabolite: '#0f7c96' }

export function typeColor(label) {
  return typeColors[label] || '#6b7280'
}
