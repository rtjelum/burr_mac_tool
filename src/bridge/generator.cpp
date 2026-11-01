/* Puzzle generator: splits a result shape into pieces and searches for a split
 * with a unique solution whose disassembly needs many moves.
 *
 * Search: random split into connected pieces, then hill climbing that moves one
 * cube at a time between neighbouring pieces; every candidate is checked with
 * the real assembler and disassembler. Restarts from a new random split when
 * it stops improving.
 */

#include "burrbridge.h"
#include "internal.h"

#include "../lib/puzzle.h"
#include "../lib/solution.h"
#include "../lib/problem.h"
#include "../lib/assembler.h"
#include "../lib/assembly.h"
#include "../lib/disassembler_0.h"
#include "../lib/disassembly.h"
#include "../lib/gridtype.h"
#include "../lib/voxel.h"
#include "../lib/bt_assert.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>


namespace {

struct Evaluation {
  bool valid = false;       // at least one solution (and only one if unique is required)
  int solutions = 0;
  int level = 0;            // moves until the first piece comes out
  int moves = 0;            // moves for the whole disassembly
  double score = -1e18;
};

class Collector : public assembler_cb {
public:
  disassembler_0_c *disassembler;
  assembler_c *assembler = 0;
  bool unique;
  int assemblies = 0, solutions = 0, level = 0, moves = 0;

  Collector(disassembler_0_c *d, bool u) : disassembler(d), unique(u) {}

  bool assembly(assembly_c *a) {
    assemblies++;
    separation_c *s = disassembler->disassemble(a);
    if (s) {
      solutions++;
      level = std::max(level, (int)s->getMoves());
      moves = std::max(moves, (int)s->sumMoves());
      delete s;
    }
    delete a;
    // a second solution already rules the design out; very many assemblies make it hopeless
    if ((unique && solutions > 1) || assemblies > 3000) assembler->stop();
    return true;
  }
};

}  // namespace

struct BTGenerator {
  // settings
  gridType_c::gridType gridType;
  voxel_c *result = 0;          // copy of the result shape
  int pieces, target, metric, minSize, holes;
  bool unique;
  // score lost per fully spidery new piece. 0 while searching for the level
  // (odd shapes help it get there); set when polishing a design that reached it
  double compactWeight = 0;
  bool compact = false;

  // starting pieces (e.g. a cage) that keep their shape; piece numbers
  // 0 .. nFixed-1 are these, nFixed .. total-1 are the generated pieces
  int nFixed = 0, total = 0;
  std::vector<voxel_c *> fixedShapes;
  std::vector<int> fixedIds;               // their shape numbers in the puzzle
  std::vector<int> fixedOwner;             // cell -> starting piece, or UNASSIGNED
  std::vector<int> seedAssign;             // an existing design to start from (empty = none)

  // the cells to split (filled voxels of the result) and their neighbours
  std::vector<int> cellVoxel;              // cell -> voxel index in the result
  std::vector<std::vector<int>> neighbours;
  std::vector<int> voxelCell;              // voxel index -> cell, or -1
  std::vector<char> variableCell;          // cell may be left empty
  std::vector<std::array<int, 3>> cellPos; // cell -> x, y, z

  std::mt19937 rng;
  std::thread worker;
  std::atomic<bool> stopRequested{false};

  // status, guarded by lock
  std::mutex lock;
  long tried = 0, validFound = 0;
  bool running = true, found = false, haveBest = false, polishing = false;
  int bestVersion = 0;
  Evaluation best;
  std::vector<int> bestAssign;  // cell -> piece
  std::string error;

  ~BTGenerator() {
    delete result;
    for (voxel_c *v : fixedShapes) delete v;
  }

  // ---- splitting ----

  /* assign[c]: piece number, or HOLE for a variable cube left empty */
  static constexpr int HOLE = -1;
  static constexpr int UNASSIGNED = -2;

  bool randomSplit(std::vector<int> &assign) {
    int n = (int)cellVoxel.size();
    std::vector<int> variableCells;
    for (int c = 0; c < n; c++) if (variableCell[c] && fixedOwner[c] == UNASSIGNED) variableCells.push_back(c);

    for (int attempt = 0; attempt < 400; attempt++) {
      assign = fixedOwner;   // starting pieces keep their cells

      // pick the holes among the variable cubes
      std::shuffle(variableCells.begin(), variableCells.end(), rng);
      for (int h = 0; h < holes; h++) assign[variableCells[h]] = HOLE;

      // size and frontier are indexed by generated piece (0 .. pieces-1)
      std::vector<int> size(pieces, 0);
      std::vector<std::vector<int>> frontier(pieces);
      std::vector<int> order;
      for (int c = 0; c < n; c++) if (assign[c] == UNASSIGNED) order.push_back(c);
      if ((int)order.size() < pieces) return false;
      std::shuffle(order.begin(), order.end(), rng);
      for (int k = 0; k < pieces; k++) {
        assign[order[k]] = nFixed + k;
        size[k] = 1;
        frontier[k] = neighbours[order[k]];
      }

      int left = (int)order.size() - pieces;
      int stuck = 0;
      while (left > 0 && stuck < n * 4) {
        // grow a piece; smaller pieces are more likely to grow, but sizes still vary
        int k;
        if (std::uniform_int_distribution<int>(0, 2)(rng) == 0) {
          k = std::uniform_int_distribution<int>(0, pieces - 1)(rng);
        } else {
          k = 0;
          for (int j = 1; j < pieces; j++)
            if (size[j] < size[k] || (size[j] == size[k] && (rng() & 1))) k = j;
        }
        auto &f = frontier[k];
        bool grew = false;
        while (!f.empty()) {
          int i = std::uniform_int_distribution<int>(0, (int)f.size() - 1)(rng);
          int c = f[i];
          f[i] = f.back();
          f.pop_back();
          if (assign[c] != UNASSIGNED) continue;
          assign[c] = nFixed + k;
          size[k]++;
          left--;
          for (int nb : neighbours[c]) if (assign[nb] == UNASSIGNED) f.push_back(nb);
          grew = true;
          break;
        }
        stuck = grew ? 0 : stuck + 1;
      }
      if (left > 0) continue;   // the holes cut some cubes off; try again
      bool ok = true;
      for (int k = 0; k < pieces; k++) if (size[k] < minSize) ok = false;
      if (ok) return true;
    }
    return false;
  }

  /* Splits the free space with random straight cuts into block-like pieces.
   * Those nearly always come apart, which gives the search a working start in
   * tight spaces such as the inside of a box. */
  bool cutSplit(std::vector<int> &assign) {
    int n = (int)cellVoxel.size();
    std::vector<int> variableCells;
    for (int c = 0; c < n; c++) if (variableCell[c] && fixedOwner[c] == UNASSIGNED) variableCells.push_back(c);

    // connected parts of a set of cells
    auto components = [&](const std::vector<int> &cells) {
      std::vector<std::vector<int>> parts;
      std::vector<char> in(n, 0), seen(n, 0);
      for (int c : cells) in[c] = 1;
      for (int c : cells) {
        if (seen[c]) continue;
        std::vector<int> part, stack(1, c);
        seen[c] = 1;
        while (!stack.empty()) {
          int x = stack.back();
          stack.pop_back();
          part.push_back(x);
          for (int nb : neighbours[x]) if (in[nb] && !seen[nb]) { seen[nb] = 1; stack.push_back(nb); }
        }
        parts.push_back(part);
      }
      return parts;
    };

    for (int attempt = 0; attempt < 100; attempt++) {
      assign = fixedOwner;
      std::shuffle(variableCells.begin(), variableCells.end(), rng);
      for (int h = 0; h < holes; h++) assign[variableCells[h]] = HOLE;
      std::vector<int> freeCells;
      for (int c = 0; c < n; c++) if (assign[c] == UNASSIGNED) freeCells.push_back(c);

      std::vector<std::vector<int>> regions = components(freeCells);
      bool failed = (int)regions.size() > pieces;
      int guard = 0;
      while (!failed && (int)regions.size() < pieces && guard++ < 200) {
        // cut one of the larger regions
        std::sort(regions.begin(), regions.end(), [](const std::vector<int> &a, const std::vector<int> &b) { return a.size() > b.size(); });
        int r = std::uniform_int_distribution<int>(0, std::min(1, (int)regions.size() - 1))(rng);
        const std::vector<int> &R = regions[r];
        int axis = std::uniform_int_distribution<int>(0, 2)(rng);
        int lo = 1 << 30, hi = -(1 << 30);
        for (int c : R) { lo = std::min(lo, cellPos[c][axis]); hi = std::max(hi, cellPos[c][axis]); }
        if (hi == lo) continue;
        int cut = std::uniform_int_distribution<int>(lo + 1, hi)(rng);
        std::vector<int> a, b;
        for (int c : R) (cellPos[c][axis] < cut ? a : b).push_back(c);
        std::vector<std::vector<int>> next;
        for (size_t i = 0; i < regions.size(); i++) if ((int)i != r) next.push_back(regions[i]);
        for (auto &part : components(a)) next.push_back(part);
        for (auto &part : components(b)) next.push_back(part);
        if ((int)next.size() > pieces) continue;   // that cut made too many bits; try another
        regions.swap(next);
      }
      if (failed || (int)regions.size() != pieces) continue;
      bool ok = true;
      for (int k = 0; k < pieces; k++) {
        if ((int)regions[k].size() < minSize) ok = false;
        for (int c : regions[k]) assign[c] = nFixed + k;
      }
      if (ok) return true;
    }
    return false;
  }

  /* Bounding-box fill of each new piece (cubes / box volume). */
  std::vector<double> boxFill(const std::vector<int> &assign) const {
    int m = total - nFixed;
    std::vector<int> n(m, 0);
    std::vector<std::array<int, 6>> b(m, {1 << 30, 1 << 30, 1 << 30, -(1 << 30), -(1 << 30), -(1 << 30)});
    for (int c = 0; c < (int)assign.size(); c++) {
      int k = assign[c] - nFixed;
      if (k < 0) continue;
      n[k]++;
      for (int a = 0; a < 3; a++) {
        b[k][a] = std::min(b[k][a], cellPos[c][a]);
        b[k][a + 3] = std::max(b[k][a + 3], cellPos[c][a]);
      }
    }
    std::vector<double> fill(m, 1.0);
    for (int k = 0; k < m; k++)
      if (n[k] > 0)
        fill[k] = n[k] / (double(b[k][3] - b[k][0] + 1) * (b[k][4] - b[k][1] + 1) * (b[k][5] - b[k][2] + 1));
    return fill;
  }

  /* Compact mode rule: no new piece may fill less than about a third of its
   * bounding box, so pieces can't spread around the puzzle as thin webs. A piece that
   * already breaks the rule (because of the start) may not get worse. */
  static constexpr double MIN_FILL = 0.35;
  bool shapeAllowed(const std::vector<double> &before, const std::vector<int> &candidate) const {
    std::vector<double> after = boxFill(candidate);
    for (size_t k = 0; k < after.size(); k++)
      if (after[k] < std::min(MIN_FILL, before[k]) - 1e-9) return false;
    return true;
  }

  /* A mutation of `current` into `candidate`; in compact mode only ones the
   * shape rule allows. */
  bool step(const std::vector<int> &current, std::vector<int> &candidate) {
    std::vector<double> before;
    if (compact) before = boxFill(current);
    for (int tries = 0; tries < 60; tries++) {
      candidate = current;
      if (!mutate(candidate)) return false;
      if (!compact || shapeAllowed(before, candidate)) return true;
    }
    return false;
  }

  /* How far the new pieces are from compact lumps: 0 for block-like pieces,
   * about 1 per piece that is all thin arms or full of gaps. Two parts:
   * - thinness: cube-to-cube contacts compared to a cube-shaped piece of the
   *   same size (a chain or branching "spider" has the fewest contacts)
   * - gaps: the part of the piece's bounding box it does not fill */
  double spideriness(const std::vector<int> &assign) const {
    double total = 0;
    for (int k = nFixed; k < this->total; k++) {
      int n = 0, contacts = 0;
      int lo[3] = {1 << 30, 1 << 30, 1 << 30}, hi[3] = {-(1 << 30), -(1 << 30), -(1 << 30)};
      for (int c = 0; c < (int)assign.size(); c++) {
        if (assign[c] != k) continue;
        n++;
        for (int nb : neighbours[c]) if (assign[nb] == k) contacts++;
        for (int a = 0; a < 3; a++) { lo[a] = std::min(lo[a], cellPos[c][a]); hi[a] = std::max(hi[a], cellPos[c][a]); }
      }
      if (n < 3) continue;
      contacts /= 2;
      double gaps = 0;
      double box = double(hi[0] - lo[0] + 1) * (hi[1] - lo[1] + 1) * (hi[2] - lo[2] + 1);
      gaps = 1.0 - n / box;
      double thin = 0;
      if (gridType == gridType_c::GT_BRICKS) {
        // a cube of n cubes has about 3n - 3n^(2/3) contacts; a chain has n - 1
        double ideal = 3.0 * n - 3.0 * std::pow(double(n), 2.0 / 3.0);
        double tree = n - 1;
        if (ideal > tree) thin = std::max(0.0, std::min(1.0, (ideal - contacts) / (ideal - tree)));
      }
      // pieces that fill little of their box (webs) count extra
      total += 0.7 * thin + 0.5 * gaps + 3.0 * std::max(0.0, 0.5 - n / box);
    }
    return total;
  }

  bool isConnected(const std::vector<int> &assign, int piece) const {
    int start = -1, count = 0;
    for (int c = 0; c < (int)assign.size(); c++)
      if (assign[c] == piece) { count++; if (start < 0) start = c; }
    if (count == 0) return false;
    std::vector<char> seen(assign.size(), 0);
    std::vector<int> stack(1, start);
    seen[start] = 1;
    int reached = 0;
    while (!stack.empty()) {
      int c = stack.back();
      stack.pop_back();
      reached++;
      for (int nb : neighbours[c])
        if (!seen[nb] && assign[nb] == piece) { seen[nb] = 1; stack.push_back(nb); }
    }
    return reached == count;
  }

  /* one or two small changes: a boundary cube moves to a neighbouring piece,
   * or a hole moves (a piece takes the hole's place and gives up another
   * variable cube) */
  bool mutate(std::vector<int> &assign) {
    int n = (int)assign.size();
    std::vector<int> size(total, 0);
    for (int a : assign) if (a >= 0) size[a]++;
    int moves = 1 + std::uniform_int_distribution<int>(0, 2)(rng) / 2;
    int done = 0;
    for (int tries = 0; tries < 300 && done < moves; tries++) {
      if (holes > 0 && std::uniform_int_distribution<int>(0, 2)(rng) == 0) {
        // move a hole
        int h = std::uniform_int_distribution<int>(0, n - 1)(rng);
        if (assign[h] != HOLE || neighbours[h].empty()) continue;
        int k = assign[neighbours[h][std::uniform_int_distribution<int>(0, (int)neighbours[h].size() - 1)(rng)]];
        if (k < nFixed) continue;   // holes and starting pieces don't move
        int c = std::uniform_int_distribution<int>(0, n - 1)(rng);
        int p = assign[c];
        if (p < nFixed || !variableCell[c] || c == h) continue;
        if (p != k && size[p] <= minSize) continue;
        assign[h] = k;
        assign[c] = HOLE;
        if (!isConnected(assign, p) || !isConnected(assign, k)) {
          assign[c] = p;
          assign[h] = HOLE;
          continue;
        }
        size[k]++;
        size[p]--;
        done++;
      } else {
        // move a boundary cube to a neighbouring piece
        int c = std::uniform_int_distribution<int>(0, n - 1)(rng);
        int from = assign[c];
        const auto &nb = neighbours[c];
        if (from < nFixed || nb.empty()) continue;
        int other = assign[nb[std::uniform_int_distribution<int>(0, (int)nb.size() - 1)(rng)]];
        if (other < nFixed || other == from || size[from] <= minSize) continue;
        assign[c] = other;
        if (!isConnected(assign, from)) {
          assign[c] = from;
          continue;
        }
        size[from]--;
        size[other]++;
        done++;
      }
    }
    return done > 0;
  }

  // ---- checking a design ----

  voxel_c *pieceVoxel(const gridType_c *gt, const std::vector<int> &assign, int k) const {
    voxel_c *v = gt->getVoxel(result->getX(), result->getY(), result->getZ(), voxel_c::VX_EMPTY);
    for (int c = 0; c < (int)assign.size(); c++)
      if (assign[c] == k) v->setState(cellVoxel[c], voxel_c::VX_FILLED);
    v->minimizePiece();
    v->initHotspot();
    return v;
  }

  Evaluation evaluate(const std::vector<int> &assign) {
    Evaluation e;
    try {
      puzzle_c pz(new gridType_c(gridType));
      const gridType_c *gt = pz.getGridType();
      voxel_c *r = gt->getVoxel(*result);
      r->initHotspot();
      unsigned int rid = pz.addShape(r);
      for (int k = 0; k < total; k++) {
        if (k < nFixed) {
          voxel_c *f = gt->getVoxel(*fixedShapes[k]);
          f->initHotspot();
          pz.addShape(f);
        } else {
          pz.addShape(pieceVoxel(gt, assign, k));
        }
      }
      problem_c *pr = pz.getProblem(pz.addProblem());
      pr->setResultId(rid);
      for (int k = 0; k < total; k++) {
        pr->setShapeMaximum(k + 1, 1);
        pr->setShapeMinimum(k + 1, 1);
      }

      assembler_c *assm = pz.getGridType()->findAssembler(*pr);
      if (!assm) return e;
      if (assm->createMatrix(false, false, false) != assembler_c::ERR_NONE) { delete assm; return e; }
      assm->reduce();
      disassembler_0_c dis(*pr);
      Collector cb(&dis, unique);
      cb.assembler = assm;
      assm->assemble(&cb);
      delete assm;

      e.solutions = cb.solutions;
      e.level = cb.level;
      e.moves = cb.moves;
      e.valid = cb.solutions >= 1 && (!unique || cb.solutions == 1);

      int mobility = 0;
      int free = freeGroups(assign, &mobility);
      double shapePenalty = compactWeight > 0 ? compactWeight * spideriness(assign) : 0;
      if (cb.solutions == 0) {
        // Locked: no way apart. If no group can slide straight out either, it
        // is close to a higher-level design: score it between level 1 and 2,
        // higher the more pieces can shift a step, so the search can work
        // its way through locked designs to one that just comes apart.
        if (metric == 0 && free == 0) e.score = 1000.0 + 25.0 * std::min(mobility, 30) - 760.0 - shapePenalty;
        return e;
      }
      int main = metric == 0 ? e.level : e.moves;
      int other = metric == 0 ? e.moves : e.level;
      e.score = main * 1000.0 + std::min(other, 99) * 2.0 - (unique ? (cb.solutions - 1) * 3000.0 : 0)
              - free * 40.0 - shapePenalty;
    } catch (...) {
      e = Evaluation();
    }
    return e;
  }

  /* Counts the ways a group of pieces can slide straight out of the assembled
   * puzzle in one move: for each direction, each piece plus everything that
   * (transitively) blocks it forms the smallest group that can move out that
   * way; if that group is not the whole puzzle, it comes out in one move and the
   * puzzle is level 1. A level 2+ design needs this to be 0, so it guides the
   * search towards interlocking designs. Cube grid only. */
  int freeGroups(const std::vector<int> &assign, int *mobility = 0) const {
    if (mobility) *mobility = 0;
    const int pieces = total;
    if (gridType != gridType_c::GT_BRICKS || pieces > 64) return 0;
    const int dirs[6][3] = { {1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1} };
    int sx = result->getX(), sy = result->getY(), sz = result->getZ();
    std::vector<int> owner(result->getXYZ(), -1);
    for (int c = 0; c < (int)assign.size(); c++) owner[cellVoxel[c]] = assign[c];   // holes stay -1
    const uint64_t all = pieces == 64 ? ~0ull : ((1ull << pieces) - 1);
    int free = 0;
    for (const auto &d : dirs) {
      // blockers[k]: pieces in the way when piece k moves in direction d
      std::vector<uint64_t> blockers(pieces, 0);
      std::vector<char> stepBlocked(pieces, 0);   // can't move even one step
      for (int c = 0; c < (int)assign.size(); c++) {
        int k = assign[c];
        if (k < 0) continue;
        unsigned int x, y, z;
        result->indexToXYZ(cellVoxel[c], &x, &y, &z);
        int px = x + d[0], py = y + d[1], pz = z + d[2];
        bool first = true;
        while (px >= 0 && py >= 0 && pz >= 0 && px < sx && py < sy && pz < sz) {
          int o = owner[result->getIndex(px, py, pz)];
          if (o >= 0 && o != k) { blockers[k] |= 1ull << o; if (first) stepBlocked[k] = 1; break; }
          first = false;
          px += d[0]; py += d[1]; pz += d[2];
        }
      }
      if (mobility) for (int k = 0; k < pieces; k++) if (!stepBlocked[k]) (*mobility)++;
      for (int k = 0; k < pieces; k++) {
        uint64_t group = 1ull << k, prev = 0;
        while (group != prev) {
          prev = group;
          for (int j = 0; j < pieces; j++) if (group & (1ull << j)) group |= blockers[j];
        }
        if (group != all) free++;
      }
    }
    return free;
  }

  int value(const Evaluation &e) const { return metric == 0 ? e.level : e.moves; }

  void record(const std::vector<int> &assign, const Evaluation &e) {
    std::lock_guard<std::mutex> g(lock);
    tried++;
    if (!e.valid) return;
    validFound++;
    if (!haveBest || value(e) > value(best) || (value(e) == value(best) && e.score > best.score)) {
      best = e;
      bestAssign = assign;
      haveBest = true;
      bestVersion++;
      if (value(e) >= target) found = true;
    }
  }

  /* After a design reaches the target: keep reshaping it towards compact
   * pieces, accepting only changes that still reach the target. */
  void polish() {
    std::vector<int> current;
    {
      std::lock_guard<std::mutex> g(lock);
      current = bestAssign;
    }
    compactWeight = 700;
    Evaluation cur = evaluate(current);
    {
      std::lock_guard<std::mutex> g(lock);
      best = cur;
      polishing = true;
    }
    int stale = 0, patience = 200 + 50 * total;
    while (!stopRequested && stale < patience) {
      std::vector<int> candidate;
      if (!step(current, candidate)) break;
      Evaluation e = evaluate(candidate);
      {
        std::lock_guard<std::mutex> g(lock);
        tried++;
        if (e.valid) validFound++;
      }
      if (e.valid && value(e) >= target && e.score > cur.score) {
        current = candidate;
        cur = e;
        stale = 0;
        std::lock_guard<std::mutex> g(lock);
        best = e;
        bestAssign = candidate;
        bestVersion++;
      } else {
        stale++;
      }
    }
  }

  void run() {
    std::vector<int> current, candidate;
    long restart = 0;
    while (!stopRequested) {
      // alternate block-like and blob-like starting splits
      bool ok;
      if (!seedAssign.empty()) {
        current = seedAssign;
        int shake = restart == 0 ? 0 : std::uniform_int_distribution<int>(1, 6)(rng);
        for (int i = 0; i < shake; i++) { std::vector<int> next; if (step(current, next)) current = next; }
        restart++;
        ok = true;
      } else {
        // alternate block-like and blob-like starting splits
        if (restart % 2 == 0) ok = cutSplit(current) || randomSplit(current);
        else ok = randomSplit(current) || cutSplit(current);
        restart++;
      }
      if (!ok) {
        std::lock_guard<std::mutex> g(lock);
        error = nFixed > 0
          ? "Could not split the space left by the starting pieces into connected pieces of at least the minimum size. It may be in more separate parts than there are new pieces."
          : "Could not split the shape into pieces of at least the minimum size.";
        break;
      }
      Evaluation cur = evaluate(current);
      record(current, cur);
      int stale = 0, patience = 40 + 15 * pieces;
      while (!stopRequested && stale < patience) {
        {
          std::lock_guard<std::mutex> g(lock);
          if (found) break;
        }
        if (!step(current, candidate)) break;
        Evaluation e = evaluate(candidate);
        record(candidate, e);
        if (e.score > cur.score) { current = candidate; cur = e; stale = 0; }
        else if (e.score == cur.score) { current = candidate; stale++; }   // drift sideways
        else stale++;
      }
      std::lock_guard<std::mutex> g(lock);
      if (found) break;
    }
    if (found && compact && !stopRequested) polish();
    std::lock_guard<std::mutex> g(lock);
    polishing = false;
    running = false;
  }
};

extern "C" {

BTGenerator *bt_generator_start(BTPuzzle *p, int shape, int pieces, int target, int metric,
                                int unique, int minSize, int holes, const int *fixed, int fixedCount,
                                int startProblem, int compact, unsigned int seed, char **error) {
  auto fail = [&](const char *msg) -> BTGenerator * {
    if (error) { *error = (char *)malloc(strlen(msg) + 1); strcpy(*error, msg); }
    return 0;
  };
  try {
    if (!p || shape < 0 || (unsigned)shape >= p->puzzle->getNumberOfShapes()) return fail("Choose a result shape.");
    const gridType_c *gt = p->puzzle->getGridType();
    if (!(gt->getCapabilities() & gridType_c::CAP_DISASSEMBLE))
      return fail("This grid type has no disassembler, so moves cannot be counted.");
    if (pieces + fixedCount < 2) return fail("Use at least 2 pieces.");
    if (pieces < 1) return fail("Generate at least 1 piece.");

    BTGenerator *g = new BTGenerator;
    g->gridType = gt->getType();
    g->result = gt->getVoxel(*p->puzzle->getShape(shape));
    g->pieces = pieces;
    g->target = std::max(1, target);
    g->metric = metric;
    g->unique = unique != 0;
    g->minSize = std::max(1, minSize);
    g->compact = compact != 0;
    g->rng.seed(seed ? seed : std::random_device()());

    const voxel_c *v = g->result;
    g->voxelCell.assign(v->getXYZ(), -1);
    for (unsigned int z = 0; z < v->getZ(); z++)
      for (unsigned int y = 0; y < v->getY(); y++)
        for (unsigned int x = 0; x < v->getX(); x++)
          if (!v->isEmpty(x, y, z)) {
            g->voxelCell[v->getIndex(x, y, z)] = (int)g->cellVoxel.size();
            g->cellVoxel.push_back(v->getIndex(x, y, z));
            g->variableCell.push_back(v->isVariable(x, y, z) ? 1 : 0);
            g->cellPos.push_back({(int)x, (int)y, (int)z});
          }
    int n = (int)g->cellVoxel.size();

    // place the starting pieces
    g->fixedOwner.assign(n, BTGenerator::UNASSIGNED);
    std::vector<int> wanted;
    for (int i = 0; i < fixedCount; i++) {
      int id = fixed[i];
      if (id < 0 || (unsigned)id >= p->puzzle->getNumberOfShapes() || id == shape) continue;
      if (std::find(wanted.begin(), wanted.end(), id) != wanted.end()) continue;
      if (p->puzzle->getShape(id)->countState(voxel_c::VX_FILLED) + p->puzzle->getShape(id)->countState(voxel_c::VX_VARIABLE) == 0) continue;
      wanted.push_back(id);
    }
    auto addFixed = [&](int id, const std::vector<int> &cells) {
      for (int c : cells) g->fixedOwner[c] = g->nFixed;
      g->fixedShapes.push_back(gt->getVoxel(*p->puzzle->getShape(id)));
      g->fixedIds.push_back(id);
      g->nFixed++;
    };

    // 1. a saved solution of a problem with this result tells exactly where they go
    for (unsigned int r = 0; r < p->puzzle->getNumberOfProblems() && !wanted.empty(); r++) {
      problem_c *pr = p->puzzle->getProblem(r);
      if (!pr->resultValid() || (int)pr->getResultId() != shape || pr->getNumberOfSavedSolutions() == 0) continue;
      const assembly_c *as = pr->getSavedSolution(0)->getAssembly();
      unsigned int pc = 0;
      for (unsigned int part = 0; part < pr->getNumberOfParts(); part++)
        for (unsigned int j = 0; j < pr->getPartMaximum(part); j++, pc++) {
          int id = pr->getShapeIdOfPart(part);
          auto w = std::find(wanted.begin(), wanted.end(), id);
          if (w == wanted.end() || !as->isPlaced(pc)) continue;
          voxel_c *t = gt->getVoxel(pr->getPartShape(part));
          bool ok = t->transform(as->getTransformation(pc));
          std::vector<int> cells;
          int ox = as->getX(pc) - t->getHx(), oy = as->getY(pc) - t->getHy(), oz = as->getZ(pc) - t->getHz();
          for (unsigned int z = 0; ok && z < t->getZ(); z++)
            for (unsigned int y = 0; ok && y < t->getY(); y++)
              for (unsigned int x = 0; ok && x < t->getX(); x++) {
                if (t->isEmpty(x, y, z)) continue;
                int rx = x + ox, ry = y + oy, rz = z + oz;
                if (rx < 0 || ry < 0 || rz < 0 || rx >= (int)v->getX() || ry >= (int)v->getY() || rz >= (int)v->getZ()) { ok = false; break; }
                int cell = g->voxelCell[v->getIndex(rx, ry, rz)];
                if (cell < 0 || g->fixedOwner[cell] != BTGenerator::UNASSIGNED) { ok = false; break; }
                cells.push_back(cell);
              }
          delete t;
          if (!ok) continue;
          addFixed(id, cells);
          wanted.erase(w);
        }
    }

    // 2. the rest: biggest first, where they are drawn if they fit there,
    //    otherwise at the nearest position where they fit (same orientation)
    std::sort(wanted.begin(), wanted.end(), [&](int a, int b) {
      return p->puzzle->getShape(a)->countState(voxel_c::VX_FILLED) > p->puzzle->getShape(b)->countState(voxel_c::VX_FILLED);
    });
    for (int id : wanted) {
      const voxel_c *f = p->puzzle->getShape(id);
      std::vector<int> fx, fy, fz;
      for (unsigned int z = 0; z < f->getZ(); z++)
        for (unsigned int y = 0; y < f->getY(); y++)
          for (unsigned int x = 0; x < f->getX(); x++)
            if (!f->isEmpty(x, y, z)) { fx.push_back(x); fy.push_back(y); fz.push_back(z); }
      int minx = *std::min_element(fx.begin(), fx.end()), maxx = *std::max_element(fx.begin(), fx.end());
      int miny = *std::min_element(fy.begin(), fy.end()), maxy = *std::max_element(fy.begin(), fy.end());
      int minz = *std::min_element(fz.begin(), fz.end()), maxz = *std::max_element(fz.begin(), fz.end());
      std::vector<std::array<int, 3>> offsets;
      for (int ox = -minx; ox + maxx < (int)v->getX(); ox++)
        for (int oy = -miny; oy + maxy < (int)v->getY(); oy++)
          for (int oz = -minz; oz + maxz < (int)v->getZ(); oz++)
            offsets.push_back({ox, oy, oz});
      std::sort(offsets.begin(), offsets.end(), [](const std::array<int, 3> &a, const std::array<int, 3> &b) {
        return std::abs(a[0]) + std::abs(a[1]) + std::abs(a[2]) < std::abs(b[0]) + std::abs(b[1]) + std::abs(b[2]);
      });
      bool placed = false;
      for (const auto &o : offsets) {
        std::vector<int> cells;
        bool fits = true;
        for (size_t j = 0; j < fx.size() && fits; j++) {
          int cell = g->voxelCell[v->getIndex(fx[j] + o[0], fy[j] + o[1], fz[j] + o[2])];
          fits = cell >= 0 && g->fixedOwner[cell] == BTGenerator::UNASSIGNED;
          cells.push_back(cell);
        }
        if (!fits) continue;
        addFixed(id, cells);
        placed = true;
        break;
      }
      if (!placed) {
        std::string name = f->getName().empty() ? "S" + std::to_string(id + 1) : f->getName();
        std::string msg = "The starting piece \"" + name + "\" does not fit inside the final shape as it is drawn. Solve a problem that uses it with this final shape first, then its position is taken from the solution.";
        delete g;
        return fail(msg.c_str());
      }
    }
    // start from an existing design: the pieces of a solved problem's first solution
    if (startProblem >= 0 && (unsigned)startProblem < p->puzzle->getNumberOfProblems()) {
      problem_c *pr = p->puzzle->getProblem(startProblem);
      if (pr->resultValid() && (int)pr->getResultId() == shape && pr->getNumberOfSavedSolutions() > 0) {
        const assembly_c *as = pr->getSavedSolution(0)->getAssembly();
        std::vector<int> assign = g->fixedOwner;
        std::vector<char> usedFixed(g->nFixed, 0);
        int generated = 0;
        bool ok = true;
        unsigned int pc = 0;
        for (unsigned int part = 0; ok && part < pr->getNumberOfParts(); part++)
          for (unsigned int j = 0; ok && j < pr->getPartMaximum(part); j++, pc++) {
            if (!as->isPlaced(pc)) continue;
            int id = pr->getShapeIdOfPart(part);
            auto f = std::find(g->fixedIds.begin(), g->fixedIds.end(), id);
            if (f != g->fixedIds.end() && !usedFixed[f - g->fixedIds.begin()]) {
              usedFixed[f - g->fixedIds.begin()] = 1;   // a starting piece, already placed
              continue;
            }
            voxel_c *t = gt->getVoxel(pr->getPartShape(part));
            ok = t->transform(as->getTransformation(pc));
            int ox = as->getX(pc) - t->getHx(), oy = as->getY(pc) - t->getHy(), oz = as->getZ(pc) - t->getHz();
            for (unsigned int z = 0; ok && z < t->getZ(); z++)
              for (unsigned int y = 0; ok && y < t->getY(); y++)
                for (unsigned int x = 0; ok && x < t->getX(); x++) {
                  if (t->isEmpty(x, y, z)) continue;
                  int rx = x + ox, ry = y + oy, rz = z + oz;
                  if (rx < 0 || ry < 0 || rz < 0 || rx >= (int)v->getX() || ry >= (int)v->getY() || rz >= (int)v->getZ()) { ok = false; break; }
                  int cell = g->voxelCell[v->getIndex(rx, ry, rz)];
                  if (cell < 0 || assign[cell] != BTGenerator::UNASSIGNED) { ok = false; break; }
                  assign[cell] = g->nFixed + generated;
                }
            delete t;
            generated++;
          }
        // cells nobody covers must be variable; they are the holes
        int seedHoles = 0;
        for (int c = 0; ok && c < n; c++)
          if (assign[c] == BTGenerator::UNASSIGNED) {
            if (!g->variableCell[c]) ok = false;
            else { assign[c] = BTGenerator::HOLE; seedHoles++; }
          }
        if (!ok || generated < 1) { delete g; return fail("Could not use that problem's solution as a start: its pieces do not match the final shape and starting pieces."); }
        pieces = generated;
        g->pieces = generated;
        holes = seedHoles;
        g->seedAssign = assign;
        int smallest = n;
        for (int k = 0; k < generated; k++) {
          int sz = 0;
          for (int a2 : assign) if (a2 == g->nFixed + k) sz++;
          smallest = std::min(smallest, sz);
        }
        g->minSize = std::min(g->minSize, smallest);   // don't rule out the start itself
      }
    }

    g->total = g->nFixed + pieces;

    int freeCells = 0, variables = 0;
    for (int c = 0; c < n; c++)
      if (g->fixedOwner[c] == BTGenerator::UNASSIGNED) { freeCells++; variables += g->variableCell[c]; }
    g->holes = std::max(0, std::min(holes, variables));
    if (holes > variables) { delete g; return fail("There are fewer free variable cubes than empty cubes asked for."); }
    if (freeCells - g->holes < pieces * g->minSize) { delete g; return fail("There is too little space left for that many pieces of the smallest size."); }

    g->neighbours.resize(n);
    for (int c = 0; c < n; c++) {
      unsigned int x, y, z;
      v->indexToXYZ(g->cellVoxel[c], &x, &y, &z);
      int idx = 0, nx, ny, nz;
      while (v->getNeighbor(idx, 0, x, y, z, &nx, &ny, &nz)) {
        idx++;
        if (nx < 0 || ny < 0 || nz < 0 || nx >= (int)v->getX() || ny >= (int)v->getY() || nz >= (int)v->getZ()) continue;
        int cell = g->voxelCell[v->getIndex(nx, ny, nz)];
        if (cell >= 0) g->neighbours[c].push_back(cell);
      }
    }

    g->worker = std::thread([g]() { g->run(); });
    return g;
  } catch (...) {
    return fail("Could not start the generator.");
  }
}

void bt_generator_status(BTGenerator *g, BTGeneratorStatus *s) {
  std::lock_guard<std::mutex> l(g->lock);
  s->tried = g->tried;
  s->valid = g->validFound;
  s->running = g->running ? 1 : 0;
  s->found = g->found ? 1 : 0;
  s->haveBest = g->haveBest ? 1 : 0;
  s->bestLevel = g->haveBest ? g->best.level : 0;
  s->bestMoves = g->haveBest ? g->best.moves : 0;
  s->bestSolutions = g->haveBest ? g->best.solutions : 0;
  s->polishing = g->polishing ? 1 : 0;
  s->bestVersion = g->bestVersion;
}

char *bt_generator_error(BTGenerator *g) {
  std::lock_guard<std::mutex> l(g->lock);
  if (g->error.empty()) return 0;
  char *r = (char *)malloc(g->error.size() + 1);
  strcpy(r, g->error.c_str());
  return r;
}

void bt_generator_stop(BTGenerator *g) { g->stopRequested = true; }

void bt_generator_free(BTGenerator *g) {
  if (!g) return;
  g->stopRequested = true;
  if (g->worker.joinable()) g->worker.join();
  delete g;
}

int bt_generator_best(BTGenerator *g, int *out, int count) {
  std::lock_guard<std::mutex> l(g->lock);
  if (!g->haveBest) return 0;
  for (int i = 0; i < count; i++) out[i] = -1;
  for (int c = 0; c < (int)g->cellVoxel.size(); c++)
    if (g->cellVoxel[c] < count) out[g->cellVoxel[c]] = g->bestAssign[c];
  return 1;
}

int bt_generator_add_best(BTGenerator *g, BTPuzzle *p, int resultShape) {
  std::vector<int> assign;
  int level, moves;
  {
    std::lock_guard<std::mutex> l(g->lock);
    if (!g->haveBest) return -1;
    assign = g->bestAssign;
    level = g->best.level;
    moves = g->best.moves;
  }
  try {
    const gridType_c *gt = p->puzzle->getGridType();
    std::vector<unsigned int> ids;
    for (int id : g->fixedIds) ids.push_back(id);
    for (int k = 0; k < g->pieces; k++) {
      voxel_c *v = g->pieceVoxel(gt, assign, g->nFixed + k);
      v->setName("Generated " + std::to_string(k + 1));
      ids.push_back(p->puzzle->addShape(v));
    }
    unsigned int prob = p->puzzle->addProblem();
    problem_c *pr = p->puzzle->getProblem(prob);
    pr->setName("Generated, level " + std::to_string(level) + ", " + std::to_string(moves) + " moves");
    pr->setResultId(resultShape);
    for (unsigned int id : ids) {
      pr->setShapeMaximum(id, 1);
      pr->setShapeMinimum(id, 1);
    }
    return (int)prob;
  } catch (...) {
    return -1;
  }
}

}  // extern "C"
