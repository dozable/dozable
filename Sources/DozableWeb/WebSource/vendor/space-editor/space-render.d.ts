// The render-only entry's API (space-render.js): a space/3 file drawn as one still SVG. See INTEGRATION.md.
import type { SpaceState } from './space-editor.js';

export interface RenderOpts {
  /** the SVG's size in px (default: hero 960 × 600, thumb 160 × 100) */
  width?: number;
  height?: number;
  /** default 'auto': the viewer's preference (prefers-color-scheme), in the SVG's own <style> */
  theme?: 'light' | 'dark' | 'auto';
  /** 'hero' (default): the full drawing, labels included. 'thumb': no text, folders, secrets or badges; reads at 160 × 100 */
  detail?: 'hero' | 'thumb';
  /** prefixed to every id in the SVG (letters, digits, - and _); default: from a hash of the inputs */
  idPrefix?: string;
  /** the margin around the drawing, in px (default: hero 16, thumb 4) */
  padding?: number;
}

/** The space drawn as SVG markup (a state: its Live layer, drawn still). The same inputs give the same bytes. A file
 *  that doesn't read gives a small problem marker and the first error's message; it never throws. */
export declare function render(text: string, state?: SpaceState, opts?: RenderOpts): string;
/** The same drawing as an element, made with createElementNS (no parser, no innerHTML). */
export declare function renderElement(text: string, state?: SpaceState, opts?: RenderOpts, d?: Document): SVGSVGElement;
