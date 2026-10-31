#!/usr/bin/env python3
"""Convert burrTxt -p output to an animated GIF using matplotlib 3D voxels."""

import argparse
import math
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor
from io import BytesIO

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from PIL import Image

# ── config ────────────────────────────────────────────────────────────────────
DURATION  = 200          # ms per frame
FIG_SIZE  = (7, 6)       # inches (render size — output is resized to GIF_SIZE)
DPI       = 400
GIF_SIZE  = (1024, 1024) # final output pixel dimensions
ELEV      = 35    # camera elevation (isometric ≈ 35°)
AZIM      = -45   # default camera azimuth
N_ROT     = 4     # rotation-only frames inserted when the movement axis changes

# RGBA face colours per piece letter (a–z, vibrant palette for dark background)
PIECE_RGBA = {
    'a': [1.00, 0.20, 0.40, 1.0],   # Hot Pink
    'b': [0.10, 0.90, 0.50, 1.0],   # Emerald
    'c': [0.00, 0.60, 1.00, 1.0],   # Electric Blue
    'd': [1.00, 0.80, 0.00, 1.0],   # Cyber Yellow
    'e': [0.70, 0.30, 1.00, 1.0],   # Neon Purple
    'f': [0.00, 0.90, 0.90, 1.0],   # Cyan
    'g': [1.00, 0.42, 0.00, 1.0],   # Orange
    'h': [0.52, 1.00, 0.00, 1.0],   # Lime
    'i': [0.18, 0.22, 1.00, 1.0],   # Indigo
    'j': [0.95, 0.05, 0.05, 1.0],   # Red
    'k': [0.00, 0.78, 0.55, 1.0],   # Sea Green
    'l': [1.00, 0.00, 0.78, 1.0],   # Magenta
    'm': [1.00, 0.65, 0.00, 1.0],   # Amber
    'n': [0.28, 0.75, 1.00, 1.0],   # Sky Blue
    'o': [1.00, 0.32, 0.15, 1.0],   # Tomato
    'p': [0.25, 1.00, 0.30, 1.0],   # Spring Green
    'q': [0.60, 0.08, 1.00, 1.0],   # Violet
    'r': [1.00, 0.88, 0.45, 1.0],   # Champagne
    's': [0.00, 0.88, 0.72, 1.0],   # Turquoise
    't': [1.00, 0.28, 0.62, 1.0],   # Deep Rose
    'u': [0.82, 1.00, 0.12, 1.0],   # Chartreuse
    'v': [0.40, 0.55, 1.00, 1.0],   # Periwinkle
    'w': [1.00, 0.52, 0.08, 1.0],   # Tangerine
    'x': [0.08, 0.68, 0.42, 1.0],   # Jade
    'y': [0.48, 0.05, 0.88, 1.0],   # Deep Violet
    'z': [0.55, 0.88, 1.00, 1.0],   # Ice Blue
}

# ── parsing ───────────────────────────────────────────────────────────────────
SEP = re.compile(r'^\s+\+[-]+\+')

PROBLEM_SEP = re.compile(r'^={10,}')

def parse_frames(text):
    """Parse burrTxt -p output → list of voxel dicts {(x,y,z): letter}.

    Coordinate convention (3-D, y-up):
        x = col_index - sx_half          left-right (0 = left edge of puzzle)
        z = z_index   - sz_half          depth      (0 = front face of puzzle)
        y = (sy_total - 1 - row_index) - sy_half    height (0 = bottom of puzzle)
    """
    # Skip everything before the first "====..." separator (shape previews, etc.)
    all_lines = text.split('\n')
    start = next((i for i, l in enumerate(all_lines) if PROBLEM_SEP.match(l)), 0)
    lines = all_lines[start:]
    raw = []
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        if SEP.match(line):
            block = []
            i += 1
            while i < len(lines):
                cline = lines[i].rstrip()
                if SEP.match(cline):
                    if block:
                        raw.append(block)
                    i += 1
                    break
                if '!' in cline:
                    block.append(cline)
                i += 1
        else:
            i += 1

    vmaps = []
    for block in raw:
        if not block:
            continue
        slices = block[0].split('!')[1::2]
        num_z  = len(slices)
        num_x  = len(slices[0])
        num_y  = len(block)
        # Skip shape-preview blocks (they have fewer slices than disassembly frames)
        if num_z < 6:
            continue

        # Offsets: burrTxt pads each axis by the full puzzle size on both sides,
        # so frames are 3× the puzzle extents and the puzzle sits in the middle third.
        sx_half = num_x // 3       # == original_sx
        sy_half = num_y // 3
        sz_half = num_z // 3

        vmap = {}
        for row_i, line in enumerate(block):
            pts = line.split('!')
            sls = [pts[j] for j in range(1, len(pts), 2)]
            for z_i, s in enumerate(sls):
                for x_i, ch in enumerate(s):
                    if ch.isalpha():
                        x =  x_i  - sx_half
                        z =  z_i  - sz_half
                        y = (num_y - 1 - row_i) - sy_half   # flip: row 0 = top
                        vmap[(x, y, z)] = ch.lower()
        if vmap:
            vmaps.append(vmap)
    return vmaps

# ── voxel rotation ────────────────────────────────────────────────────────────
def _rotation_matrix(x, y, z, deg):
    """Axis-angle rotation matrix for axis (x,y,z) by deg degrees."""
    axis = np.array([x, y, z], dtype=float)
    axis /= np.linalg.norm(axis)
    nx, ny, nz = axis
    c, s, t = math.cos(math.radians(deg)), math.sin(math.radians(deg)), 1 - math.cos(math.radians(deg))
    return np.array([
        [t*nx*nx + c,    t*nx*ny - s*nz, t*nx*nz + s*ny],
        [t*nx*ny + s*nz, t*ny*ny + c,    t*ny*nz - s*nx],
        [t*nx*nz - s*ny, t*ny*nz + s*nx, t*nz*nz + c   ],
    ])

def _rotate_vmap(vmap, R):
    """Apply rotation matrix R to every voxel coordinate (rounds to nearest integer)."""
    result = {}
    for (x, y, z), piece in vmap.items():
        rx, ry, rz = R @ np.array([x, y, z])
        result[(round(rx), round(ry), round(rz))] = piece
    return result

# ── camera angle ──────────────────────────────────────────────────────────────
# mpl axes: X=puzzle-x, Y=puzzle-z, Z=puzzle-y(up).
# Camera at azim θ sits in direction (cos θ, sin θ) of the mpl X-Y plane, so the
# viewing vector projected onto puzzle x-z is (-cos θ, -sin θ).

def _detect_move(prev_vmap, curr_vmap):
    """Return (dx, dz) horizontal movement between frames, or None if nothing moved."""
    added   = [p for p in curr_vmap if p not in prev_vmap]
    removed = [p for p in prev_vmap if p not in curr_vmap]
    if not added or not removed:
        return None
    dx = sum(p[0] for p in added) / len(added) - sum(p[0] for p in removed) / len(removed)
    dz = sum(p[2] for p in added) / len(added) - sum(p[2] for p in removed) / len(removed)
    return dx, dz

def _move_axis(dx, dz):
    """Classify movement as 'x', 'z', or 'mixed'."""
    if abs(dx) > abs(dz) * 1.5:
        return 'x'
    if abs(dz) > abs(dx) * 1.5:
        return 'z'
    return 'mixed'

# Best azimuth per movement axis: X-moves show best from a side angle, Z from front.
_AXIS_AZIM = {'x': -75, 'z': -15, 'mixed': -45}

# ── renderer ──────────────────────────────────────────────────────────────────
def render_frame(vmap, bounds, azim=None):
    """Render one voxel map as a PIL Image using matplotlib 3D voxels."""
    if azim is None:
        azim = AZIM
    (x0, x1), (y0, y1), (z0, z1) = bounds
    nx = x1 - x0 + 1
    ny = y1 - y0 + 1
    nz = z1 - z0 + 1

    # filled[ix, iz, iy] — mpl axes: X=puzzle-x, Y=puzzle-z, Z=puzzle-y (up)
    filled     = np.zeros((nx, nz, ny), dtype=bool)
    facecolors = np.zeros((nx, nz, ny, 4))

    for (x, y, z), piece in vmap.items():
        ix = x - x0;  iy = y - y0;  iz = z - z0
        if 0 <= ix < nx and 0 <= iy < ny and 0 <= iz < nz:
            filled[ix, iz, iy]     = True
            facecolors[ix, iz, iy] = PIECE_RGBA.get(piece, [0.5, 0.5, 0.5, 1.0])

    fig = plt.figure(figsize=FIG_SIZE, dpi=DPI, facecolor='none')
    ax  = fig.add_subplot(111, projection='3d', facecolor='none')

    ax.voxels(filled, facecolors=facecolors,
              edgecolors=(0.1, 0.1, 0.1, 0.8), linewidth=0.3)

    ax.set_xlim(0, nx);  ax.set_ylim(0, nz);  ax.set_zlim(0, ny)
    ax.set_box_aspect([nx, nz, ny])
    ax.set_axis_off()
    ax.view_init(elev=ELEV, azim=azim)

    buf = BytesIO()
    plt.savefig(buf, format='png', dpi=DPI,
                bbox_inches='tight', transparent=True, edgecolor='none')
    buf.seek(0)
    img = Image.open(buf).convert('RGBA').resize(GIF_SIZE, Image.LANCZOS)
    plt.close(fig)
    buf.close()

    # Create a vertical gradient background (Dark Modern Studio)
    bg = Image.new('RGBA', GIF_SIZE)
    top_color = (40, 42, 48)       # Deep Charcoal
    bot_color = (15, 16, 18)       # Near Black
    
    # Generate 1px wide gradient and stretch it
    base = Image.new('RGB', (1, GIF_SIZE[1]))
    for y in range(GIF_SIZE[1]):
        t = y / (GIF_SIZE[1] - 1)
        r = int(top_color[0] + (bot_color[0] - top_color[0]) * t)
        g = int(top_color[1] + (bot_color[1] - top_color[1]) * t)
        b = int(top_color[2] + (bot_color[2] - top_color[2]) * t)
        base.putpixel((0, y), (r, g, b))
    
    bg_img = base.resize(GIF_SIZE).convert('RGBA')
    
    # Composite: render sits on top of gradient
    final = Image.alpha_composite(bg_img, img)
    return final.convert('RGB')

# ── parallel worker (module-level so ProcessPoolExecutor can pickle it) ───────
def _render_worker(args):
    vmap, bounds, azim = args
    return render_frame(vmap, bounds, azim)

# ── main ─────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description='Convert burrTxt -p output to an animated GIF.')
    parser.add_argument('input',  help='burrTxt -p output file')
    parser.add_argument('output', help='output path (.gif or .png)')
    parser.add_argument('--frame', type=int, help='render only this frame index (0-based)')
    parser.add_argument('--rotate', nargs=4, type=float, metavar=('X', 'Y', 'Z', 'DEG'),
                        help='initial puzzle rotation: axis (X Y Z) and angle DEG degrees'
                             ' e.g. --rotate 0 1 0 90')
    args = parser.parse_args()

    with open(args.input) as f:
        text = f.read()

    vmaps = parse_frames(text)

    if args.frame is not None:
        if 0 <= args.frame < len(vmaps):
            vmaps = [vmaps[args.frame]]
            print(f"Selecting single frame {args.frame}")
        else:
            print(f"Error: frame index {args.frame} out of range (0-{len(vmaps)-1})")
            sys.exit(1)

    if args.rotate:
        R = _rotation_matrix(*args.rotate)
        vmaps = [_rotate_vmap(v, R) for v in vmaps]
        print(f"Applied rotation: axis=({args.rotate[0]},{args.rotate[1]},{args.rotate[2]}) "
              f"deg={args.rotate[3]}")
    print(f"Parsed {len(vmaps)} disassembly frames")

    # Compute global bounds across all frames (consistent viewport)
    # Add 1-unit margin so voxel faces at the extremes are not clipped.
    all_x = [p[0] for v in vmaps for p in v]
    all_y = [p[1] for v in vmaps for p in v]
    all_z = [p[2] for v in vmaps for p in v]
    bounds = (
        (min(all_x) - 1, max(all_x) + 1),
        (min(all_y) - 1, max(all_y) + 1),
        (min(all_z) - 1, max(all_z) + 1),
    )
    print(f"Bounds  x:{bounds[0]}  y:{bounds[1]}  z:{bounds[2]}")

    # Build frame sequence.  Rotate to the best viewing angle whenever the dominant
    # movement axis changes (X ↔ Z ↔ mixed).  Hold the puzzle still for N_ROT frames
    # during the rotation so the viewer can follow the camera before the piece moves.
    frame_seq = []   # list of (vmap, azim_deg)
    cur_axis  = None
    cur_azim  = AZIM
    frame_seq.append((vmaps[0], cur_azim))

    for i in range(1, len(vmaps)):
        move = _detect_move(vmaps[i - 1], vmaps[i])
        if move is not None:
            axis = _move_axis(*move)
            if axis != cur_axis:
                target = _AXIS_AZIM[axis]
                if target != cur_azim:
                    for r in range(1, N_ROT + 1):
                        t = r / N_ROT
                        frame_seq.append((vmaps[i - 1], cur_azim + (target - cur_azim) * t))
                    cur_azim = target
                cur_axis = axis
        frame_seq.append((vmaps[i], cur_azim))

    n_frames = len(frame_seq)
    render_args = [(vmap, bounds, azim) for vmap, azim in frame_seq]

    n_workers = os.cpu_count() or 4
    print(f"Rendering {n_frames} frames using {n_workers} workers...")
    imgs = []
    with ProcessPoolExecutor(max_workers=n_workers) as executor:
        for i, img in enumerate(executor.map(_render_worker, render_args), 1):
            print(f"  rendered frame {i}/{n_frames}...", end='\r')
            imgs.append(img)
    print()

    # Save as animated GIF or static image
    out = args.output
    if out.lower().endswith('.gif') and len(imgs) > 1:
        palettized = [img.quantize(colors=256, dither=Image.Dither.NONE) for img in imgs]
        palettized[0].save(
            out, save_all=True, append_images=palettized[1:],
            duration=DURATION, loop=0, optimize=False,
        )
        print(f"Saved {out}  ({len(imgs)} frames, {imgs[0].size[0]}×{imgs[0].size[1]}px)")
    else:
        # Save as a static image (e.g. .png)
        # If it was meant to be a GIF but only has one frame, it still works.
        imgs[0].save(out)
        print(f"Saved {out}  ({imgs[0].size[0]}×{imgs[0].size[1]}px)")

if __name__ == '__main__':
    main()
