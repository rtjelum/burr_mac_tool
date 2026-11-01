# BurrTools for Mac

A native macOS app (SwiftUI) for designing, solving and generating burr-type
puzzles, built on the solver from [BurrTools](https://burrtools.sourceforge.net)
by Andreas Röver. It opens and saves the usual `.xmpuzzle` files.

## Build and run

Needs macOS 14 or later and only the Xcode Command Line Tools
(`xcode-select --install`):

```sh
mac/build-app.sh          # creates build/BurrTools.app
open build/BurrTools.app
```

## Features

* Opens and saves `.xmpuzzle` files, with undo/redo for every change. At
  launch it shows the Open dialog (File → New makes a new puzzle).
* Shows shapes and solutions in 3D for every grid type (cubes, prisms,
  spheres, rhombic, tetra-octa).
* Edits cube-grid shapes layer by layer with a Filled / Variable / Empty pen
  (hold Option for variable cubes).
* Fill tools for whole shapes (all grids): fill or clear everything, fill
  enclosed holes, make the inside or outside variable or filled, hollow out,
  make all cubes variable or filled. "New Box…" makes a box that is solid,
  hollow, all variable, or variable inside (a result shape whose centre may
  stay empty, like Borneo).
* Puzzle generator (+ → Generate Puzzle…): pick a final shape, the number of
  pieces and the minimum number of moves (level, or total moves). It splits
  the shape's cubes (fixed and variable, leaving a chosen number of variable
  cubes empty, like Borneo) into connected pieces and searches in the background for a design
  with one solution that reaches the target, checking every candidate with the
  real solver. The best design can be added to the puzzle and is solved right
  away. Options:
  * **Starting pieces**: keep shapes such as a cage or box unchanged and
    generate only the pieces that fill the rest. They are placed as in a saved
    solution of a problem with the same final shape, otherwise where they are
    drawn or the nearest place they fit.
  * **Start from** an existing solved design: reshape its pieces step by step
    instead of starting from random splits. Use this for tight designs such as
    boxes, where random pieces almost never come apart.
  * **Compact pieces** (on by default): no new piece may spread out as a thin
    web (each must fill at least about a third of its bounding box), and once
    a design reaches the target it keeps reshaping the pieces towards solid
    blocks while the design still has one solution and reaches the target.
    The search takes longer; Add to Puzzle takes the best design so far.
  Note: a completely solid box only gives level-1 puzzles; for higher
  levels the shape needs empty or variable space inside (e.g. Make Inside
  Variable) or gaps.
* Max holes per problem: how many variable cubes may stay empty (used when a
  piece count is a range).
* Sets up problems (result shape, how many copies of each piece) and solves
  them in the background, with progress, stop and continue.
* Plays the disassembly of each solution as an animation.
* Exports the disassembly as an MP4 video or animated GIF (Export GIF… under
  the solution viewer), in two looks:
  * **Studio** (default): glossy toy-plastic pieces with rounded edges, studio
    lighting, reflections, soft shadows and a dark smoky background. MP4 is the
    default format; GIF's 256 colours make the soft gradients band.
  * **Classic**: flat matplotlib-style cubes with grid lines.

  Also works from the command line:

  ```sh
  build/BurrTools.app/Contents/MacOS/BurrTools --export-gif puzzle.xmpuzzle out.mp4 \
      [--style studio|classic] [--problem N] [--solution N] [--size 1024] \
      [--frames-per-move N] [--camera follow|fixed|orbit] \
      [--colors vibrant|toy|burrtools] [--background dark|light|white] [--solve]
  ```

  The file type follows the name: `.gif`, `.mp4`, or `.png` for a single
  frame (choose it with `--frame N`).
* Exports pieces as STL files for 3D printing (File → Export STL…, ⇧⌘E).
  Enter the size of the assembled puzzle and the clearance between pieces;
  the app works out the unit size and face offset, shows the printed size of
  each piece, and writes one file per shape.

Not in this app (they were in the original FLTK BurrTools): editing shapes on
non-cube grids, piece groups, colour constraints, placement and movement
browsers, marking hole faces for hollow STL pieces, and Lua scripting.

## Code layout

* `Package.swift`: Swift package. Builds the C++ solver as the `BurrCore`
  target and the app as `BurrToolsApp`.
* `mac/BurrToolsApp/`: the SwiftUI app.
* `mac/build-app.sh`, `mac/Info.plist`, `mac/AppIcon.ico`: app bundle.
* `src/lib/`, `src/halfedge/`, `src/tools/`: the BurrTools C++ solver and
  mesh code (with fixes for current compilers and the text disassembly output).
* `src/bridge/`: the C interface the app calls, and the puzzle generator.
* `examples/`: example puzzles.

## Credits and licence

The solver is BurrTools by Andreas Röver, with small patches from several
authors (see `AUTHORS`). Licensed under the GNU GPL, version 2 or later
(see `COPYING` and `COPYRIGHT`).
