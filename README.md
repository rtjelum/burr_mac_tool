This repository contains the BurrTools code with some modernisations
to make it run on modern systems. You can download BurrTools from the 
[Releases page](https://github.com/burr-tools/burr-tools/releases/).

## Native macOS app (SwiftUI)

`mac/` contains a new native Mac app written in SwiftUI. It replaces the old
FLTK/OpenGL interface but uses the same C++ solver (`src/lib`), so solving
results are the same. It opens and saves the usual `.xmpuzzle` files.

Build it with only the Xcode Command Line Tools (`xcode-select --install`):

```sh
mac/build-app.sh          # creates build/BurrTools.app
open build/BurrTools.app
```

What it does:

* Opens and saves `.xmpuzzle` files, with undo/redo for every change.
* Shows shapes and solutions in 3D for every grid type (cubes, prisms,
  spheres, rhombic, tetra-octa).
* Edits cube-grid shapes layer by layer (click or drag to add or remove cubes;
  hold Option for variable cubes).
* Sets up problems (result shape, how many copies of each piece) and solves
  them in the background, with progress, stop and continue.
* Plays the disassembly of each solution as an animation.

Not yet in the new app (use the old app for these): editing shapes on non-cube
grids, piece groups, colour constraints, placement and movement browsers,
STL/image export, and the shape-generating tools.

How it fits together: `Package.swift` builds the C++ library as the `BurrCore`
target, with a small C interface in `src/bridge/`. The SwiftUI code is in
`mac/BurrToolsApp/`.

This fork ([burr_mac_tool](https://github.com/rtjelum/burr_mac_tool)) adds:

* **Fixed text disassembly output** (`burrTxt -p`): no longer crashes when
  some pieces are left out of an assembly, and removed/remaining piece groups
  now use the correct piece shapes. Each frame is padded by the full puzzle
  size, so pieces moving out of the puzzle stay visible.
* **`scripts/burr2gif.py`**: turns `burrTxt -p` output into an animated 3D GIF.

  ```sh
  pip install -r scripts/requirements-burr2gif.txt
  burrTxt -d -p puzzle.xmpuzzle > solution.txt
  python3 scripts/burr2gif.py solution.txt solution.gif
  # options: --frame N (render one frame), --rotate X Y Z DEG (initial rotation)
  ```

  Sample input and output are in `scripts/burr2gif-samples/`.

BurrTools was written by Andreas Röver, small patches provided by
several authors. Original README below.

---

BurrTools is a library to solve burr-type puzzles. Bundled with the
library comes a graphical program that lets you edit the puzzles and
view the found solutions.

The real documentation is inside the executable-file as on-line help.
And also available as a pdf for off-line reading or printouts.

I've also been able to bundle a few puzzles with the program to
demonstrate its features. Thanks to the designers. You can find these
puzzles in the examples subdirectory.

The library that contains all the mathematical and algorithmical stuff
is documented using doxygen. You can generate that documentation using
the doxygen.cfg file that is in the source-code of the program. I tried
to include algorithmic as well as organisatorical comments into the
doxygen documentation.

Have fun.


   Andreas Röver

---

* [Build Instructions](BUILD.md)
* [User Guide](https://burrtools.sourceforge.net/gui-doc/toc.html)
* [Library documentation](https://burrtools.sourceforge.net/lib-doc/index.html)
