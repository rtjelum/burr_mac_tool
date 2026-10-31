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
#include "../lib/problem.h"
#include "../lib/assembler.h"
#include "../lib/assembly.h"
#include "../lib/disassembler_0.h"
#include "../lib/disassembly.h"
#include "../lib/gridtype.h"
#include "../lib/voxel.h"
#include "../lib/bt_assert.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
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
  int pieces, target, metric, minSize;
  bool unique;

  // the cells to split (filled voxels of the result) and their neighbours
  std::vector<int> cellVoxel;              // cell -> voxel index in the result
  std::vector<std::vector<int>> neighbours;
  std::vector<int> voxelCell;              // voxel index -> cell, or -1

  std::mt19937 rng;
  std::thread worker;
  std::atomic<bool> stopRequested{false};

  // status, guarded by lock
  std::mutex lock;
  long tried = 0, validFound = 0;
  bool running = true, found = false, haveBest = false;
  Evaluation best;
  std::vector<int> bestAssign;  // cell -> piece
  std::string error;

  ~BTGenerator() { delete result; }

  // ---- splitting ----

  bool randomSplit(std::vector<int> &assign) {
    int n = (int)cellVoxel.size();
    for (int attempt = 0; attempt < 200; attempt++) {
      assign.assign(n, -1);
      std::vector<int> size(pieces, 0);
      std::vector<std::vector<int>> frontier(pieces);

      std::vector<int> order(n);
      for (int i = 0; i < n; i++) order[i] = i;
      std::shuffle(order.begin(), order.end(), rng);
      for (int k = 0; k < pieces; k++) {
        assign[order[k]] = k;
        size[k] = 1;
        frontier[k] = neighbours[order[k]];
      }

      int left = n - pieces;
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
          if (assign[c] != -1) continue;
          assign[c] = k;
          size[k]++;
          left--;
          for (int nb : neighbours[c]) if (assign[nb] == -1) f.push_back(nb);
          grew = true;
          break;
        }
        stuck = grew ? 0 : stuck + 1;
      }
      if (left > 0) continue;
      bool ok = true;
      for (int k = 0; k < pieces; k++) if (size[k] < minSize) ok = false;
      if (ok) return true;
    }
    return false;
  }

  bool connectedWithout(const std::vector<int> &assign, int piece, int removed) {
    int start = -1, count = 0;
    for (int c = 0; c < (int)assign.size(); c++)
      if (assign[c] == piece && c != removed) { count++; if (start < 0) start = c; }
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
        if (!seen[nb] && nb != removed && assign[nb] == piece) { seen[nb] = 1; stack.push_back(nb); }
    }
    return reached == count;
  }

  /* move one to three boundary cubes to a neighbouring piece */
  bool mutate(std::vector<int> &assign) {
    std::vector<int> size(pieces, 0);
    for (int a : assign) size[a]++;
    int moves = 1 + std::uniform_int_distribution<int>(0, 2)(rng) / 2;
    int done = 0;
    for (int tries = 0; tries < 200 && done < moves; tries++) {
      int c = std::uniform_int_distribution<int>(0, (int)assign.size() - 1)(rng);
      const auto &nb = neighbours[c];
      if (nb.empty()) continue;
      int other = assign[nb[std::uniform_int_distribution<int>(0, (int)nb.size() - 1)(rng)]];
      int from = assign[c];
      if (other == from || size[from] <= minSize) continue;
      if (!connectedWithout(assign, from, c)) continue;
      assign[c] = other;
      size[from]--;
      size[other]++;
      done++;
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
      for (int k = 0; k < pieces; k++) pz.addShape(pieceVoxel(gt, assign, k));
      problem_c *pr = pz.getProblem(pz.addProblem());
      pr->setResultId(rid);
      for (int k = 0; k < pieces; k++) {
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
      if (cb.solutions == 0) {
        // Locked: no way apart. If no group can slide straight out either, it
        // is close to a higher-level design: score it between level 1 and 2,
        // higher the more pieces can shift a step, so the search can work
        // its way through locked designs to one that just comes apart.
        if (metric == 0 && free == 0) e.score = 1000.0 + 25.0 * std::min(mobility, 30) - 760.0;
        return e;
      }
      int main = metric == 0 ? e.level : e.moves;
      int other = metric == 0 ? e.moves : e.level;
      e.score = main * 1000.0 + std::min(other, 99) * 2.0 - (unique ? (cb.solutions - 1) * 3000.0 : 0)
              - free * 40.0;
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
    if (gridType != gridType_c::GT_BRICKS || pieces > 64) return 0;
    const int dirs[6][3] = { {1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1} };
    int sx = result->getX(), sy = result->getY(), sz = result->getZ();
    std::vector<int> owner(result->getXYZ(), -1);
    for (int c = 0; c < (int)assign.size(); c++) owner[cellVoxel[c]] = assign[c];
    const uint64_t all = pieces == 64 ? ~0ull : ((1ull << pieces) - 1);
    int free = 0;
    for (const auto &d : dirs) {
      // blockers[k]: pieces in the way when piece k moves in direction d
      std::vector<uint64_t> blockers(pieces, 0);
      std::vector<char> stepBlocked(pieces, 0);   // can't move even one step
      for (int c = 0; c < (int)assign.size(); c++) {
        int k = assign[c];
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
      if (value(e) >= target) found = true;
    }
  }

  void run() {
    std::vector<int> current, candidate;
    while (!stopRequested) {
      if (!randomSplit(current)) {
        std::lock_guard<std::mutex> g(lock);
        error = "Could not split the shape into pieces of at least the minimum size.";
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
        candidate = current;
        if (!mutate(candidate)) break;
        Evaluation e = evaluate(candidate);
        record(candidate, e);
        if (e.score > cur.score) { current = candidate; cur = e; stale = 0; }
        else if (e.score == cur.score) { current = candidate; stale++; }   // drift sideways
        else stale++;
      }
      std::lock_guard<std::mutex> g(lock);
      if (found) break;
    }
    std::lock_guard<std::mutex> g(lock);
    running = false;
  }
};

extern "C" {

BTGenerator *bt_generator_start(BTPuzzle *p, int shape, int pieces, int target, int metric,
                                int unique, int minSize, unsigned int seed, char **error) {
  auto fail = [&](const char *msg) -> BTGenerator * {
    if (error) { *error = (char *)malloc(strlen(msg) + 1); strcpy(*error, msg); }
    return 0;
  };
  try {
    if (!p || shape < 0 || (unsigned)shape >= p->puzzle->getNumberOfShapes()) return fail("Choose a result shape.");
    const gridType_c *gt = p->puzzle->getGridType();
    if (!(gt->getCapabilities() & gridType_c::CAP_DISASSEMBLE))
      return fail("This grid type has no disassembler, so moves cannot be counted.");
    if (pieces < 2) return fail("Use at least 2 pieces.");

    BTGenerator *g = new BTGenerator;
    g->gridType = gt->getType();
    g->result = gt->getVoxel(*p->puzzle->getShape(shape));
    g->pieces = pieces;
    g->target = std::max(1, target);
    g->metric = metric;
    g->unique = unique != 0;
    g->minSize = std::max(1, minSize);
    g->rng.seed(seed ? seed : std::random_device()());

    const voxel_c *v = g->result;
    g->voxelCell.assign(v->getXYZ(), -1);
    for (unsigned int z = 0; z < v->getZ(); z++)
      for (unsigned int y = 0; y < v->getY(); y++)
        for (unsigned int x = 0; x < v->getX(); x++)
          if (v->isFilled(x, y, z)) {
            g->voxelCell[v->getIndex(x, y, z)] = (int)g->cellVoxel.size();
            g->cellVoxel.push_back(v->getIndex(x, y, z));
          }
    int n = (int)g->cellVoxel.size();
    if (n < pieces * g->minSize) { delete g; return fail("The shape has too few filled cubes for that many pieces."); }

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
    for (int k = 0; k < g->pieces; k++) {
      voxel_c *v = g->pieceVoxel(gt, assign, k);
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
