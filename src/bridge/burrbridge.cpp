/* C interface to the BurrTools library, used by the Swift app. */

#include "burrbridge.h"

#include "../lib/puzzle.h"
#include "../lib/problem.h"
#include "../lib/solution.h"
#include "../lib/assembly.h"
#include "../lib/disassembly.h"
#include "../lib/disasmtomoves.h"
#include "../lib/gridtype.h"
#include "../lib/voxel.h"
#include "../lib/solvethread.h"
#include "../lib/bt_assert.h"
#include "../halfedge/polyhedron.h"
#include "../halfedge/face.h"
#include "../halfedge/halfedge.h"
#include "../halfedge/vertex.h"
#include "../halfedge/modifiers.h"
#include "../lib/stl.h"
#include "../tools/xml.h"
#include "../tools/gzstream.h"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>
#include <thread>
#include <vector>

struct BTPuzzle {
  puzzle_c *puzzle;
};

struct BTSolver {
  solveThread_c *thread;
};

struct BTScenePiece {
  voxel_c *voxel;   // transformed piece, NULL if not placed
  int shape;
  int copy;
  float x, y, z, alpha;
};

struct BTScene {
  std::vector<BTScenePiece> pieces;
  disasmToMoves_c *moves;
  int steps;
  float cx, cy, cz;   // centre of the assembled puzzle
};

/* ---- helpers ---- */

static char *dupString(const std::string &s) {
  char *r = (char *)malloc(s.size() + 1);
  memcpy(r, s.c_str(), s.size() + 1);
  return r;
}

static void setError(char **error, const std::string &msg) {
  if (error) *error = dupString(msg);
}

static std::string describe(const assert_exception &e) {
  if (!e.expr) return "internal error";
  return std::string("internal error: ") + e.expr + " (" + (e.file ? e.file : "?") + ":" + std::to_string(e.line) + ")";
}

#define GUARD_BEGIN try {
#define GUARD_END(error, ret)                                         \
  } catch (assert_exception &e) { setError(error, describe(e)); return ret; } \
  catch (std::exception &e) { setError(error, e.what()); return ret; }        \
  catch (...) { setError(error, "unknown error"); return ret; }

static bool validShape(BTPuzzle *p, int s) { return p && s >= 0 && (unsigned)s < p->puzzle->getNumberOfShapes(); }
static bool validProblem(BTPuzzle *p, int r) { return p && r >= 0 && (unsigned)r < p->puzzle->getNumberOfProblems(); }

static BTMesh *meshFromPolyhedron(Polyhedron *poly, float ox, float oy, float oz) {
  std::vector<float> pos, nrm;
  std::vector<unsigned char> light, variable;

  for (Polyhedron::const_face_iterator it = poly->fBegin(); it != poly->fEnd(); it++) {
    const Face *f = *it;
    if (f->hole()) continue;
    if (f->_flags & FF_INSIDE_FACE) continue;

    Vector3Df n = f->normal();

    // fan triangulation, same as the original OpenGL renderer
    Face::const_edge_circulator e = f->begin();
    Face::const_edge_circulator sentinel = e;
    e++;
    Vector3Df start = (*e)->dst()->position();
    e++;
    do {
      Vector3Df b = (*e)->dst()->position();
      e++;
      Vector3Df c = (*e)->dst()->position();
      const Vector3Df *vs[3] = { &start, &b, &c };
      for (int i = 0; i < 3; i++) {
        pos.push_back(vs[i]->x() - ox);
        pos.push_back(vs[i]->y() - oy);
        pos.push_back(vs[i]->z() - oz);
        nrm.push_back(n.x());
        nrm.push_back(n.y());
        nrm.push_back(n.z());
      }
      light.push_back((f->_flags & FF_COLOR_LIGHT) ? 1 : 0);
      variable.push_back((f->_flags & FF_VARIABLE_FACE) ? 1 : 0);
    } while (e != sentinel);
  }

  if (light.empty()) return 0;

  BTMesh *m = (BTMesh *)malloc(sizeof(BTMesh));
  m->triangleCount = (int)light.size();
  m->positions = (float *)malloc(pos.size() * sizeof(float));
  m->normals = (float *)malloc(nrm.size() * sizeof(float));
  m->light = (unsigned char *)malloc(light.size());
  m->variable = (unsigned char *)malloc(variable.size());
  memcpy(m->positions, pos.data(), pos.size() * sizeof(float));
  memcpy(m->normals, nrm.data(), nrm.size() * sizeof(float));
  memcpy(m->light, light.data(), light.size());
  memcpy(m->variable, variable.data(), variable.size());
  return m;
}

static BTMesh *meshFromVoxel(const voxel_c *v, float ox, float oy, float oz) {
  if (v->countState(voxel_c::VX_FILLED) + v->countState(voxel_c::VX_VARIABLE) == 0) return 0;
  Polyhedron *poly = v->getDrawingMesh();
  if (!poly) return 0;
  BTMesh *m = meshFromPolyhedron(poly, ox, oy, oz);
  delete poly;
  return m;
}

/* ---- general ---- */

void bt_free(void *ptr) { free(ptr); }

void bt_mesh_free(BTMesh *m) {
  if (!m) return;
  free(m->positions);
  free(m->normals);
  free(m->light);
  free(m->variable);
  free(m);
}

/* ---- puzzle ---- */

BTPuzzle *bt_puzzle_new(int gridType) {
  GUARD_BEGIN
  if (gridType < 0 || gridType >= gridType_c::GT_NUM_GRIDS) gridType = 0;
  BTPuzzle *p = new BTPuzzle;
  p->puzzle = new puzzle_c(new gridType_c((gridType_c::gridType)gridType));
  return p;
  GUARD_END(nullptr, nullptr)
}

BTPuzzle *bt_puzzle_load(const char *path, char **error) {
  std::istream *str = 0;
  try {
    str = openGzFile(path);
    if (!str || !*str) {
      delete str;
      setError(error, "could not open file");
      return 0;
    }
    xmlParser_c pars(*str);
    puzzle_c *pz = new puzzle_c(pars);
    delete str;
    for (unsigned int i = 0; i < pz->getNumberOfShapes(); i++)
      pz->getShape(i)->initHotspot();
    BTPuzzle *p = new BTPuzzle;
    p->puzzle = pz;
    return p;
  }
  catch (xmlParserException_c &e) { delete str; setError(error, e.what()); }
  catch (assert_exception &e) { delete str; setError(error, describe(e)); }
  catch (std::exception &e) { delete str; setError(error, e.what()); }
  catch (...) { delete str; setError(error, "unknown error while loading"); }
  return 0;
}

int bt_puzzle_save(BTPuzzle *p, const char *path, char **error) {
  GUARD_BEGIN
  ogzstream ostr(path);
  if (!ostr) { setError(error, "could not open file for writing"); return 0; }
  {
    xmlWriter_c xml(ostr);
    p->puzzle->save(xml);
  }
  ostr.close();
  if (!ostr) { setError(error, "error while writing file"); return 0; }
  return 1;
  GUARD_END(error, 0)
}

void bt_puzzle_free(BTPuzzle *p) {
  if (!p) return;
  delete p->puzzle;
  delete p;
}

int bt_puzzle_grid_type(BTPuzzle *p) { return p->puzzle->getGridType()->getType(); }

int bt_puzzle_can_assemble(BTPuzzle *p) {
  return (p->puzzle->getGridType()->getCapabilities() & gridType_c::CAP_ASSEMBLE) ? 1 : 0;
}

int bt_puzzle_can_disassemble(BTPuzzle *p) {
  return (p->puzzle->getGridType()->getCapabilities() & gridType_c::CAP_DISASSEMBLE) ? 1 : 0;
}

char *bt_puzzle_comment(BTPuzzle *p) { return dupString(p->puzzle->getComment()); }
void bt_puzzle_set_comment(BTPuzzle *p, const char *c) { p->puzzle->setComment(c ? c : ""); }

/* ---- shapes ---- */

int bt_shape_count(BTPuzzle *p) { return p ? (int)p->puzzle->getNumberOfShapes() : 0; }

int bt_shape_add(BTPuzzle *p, int sx, int sy, int sz) {
  GUARD_BEGIN
  return (int)p->puzzle->addShape(sx, sy, sz);
  GUARD_END(nullptr, -1)
}

void bt_shape_remove(BTPuzzle *p, int s) {
  GUARD_BEGIN
  if (validShape(p, s)) p->puzzle->removeShape(s);
  GUARD_END(nullptr, )
}

char *bt_shape_name(BTPuzzle *p, int s) {
  if (!validShape(p, s)) return dupString("");
  return dupString(p->puzzle->getShape(s)->getName());
}

void bt_shape_set_name(BTPuzzle *p, int s, const char *name) {
  if (validShape(p, s)) p->puzzle->getShape(s)->setName(name ? name : "");
}

void bt_shape_size(BTPuzzle *p, int s, int *sx, int *sy, int *sz) {
  *sx = *sy = *sz = 0;
  if (!validShape(p, s)) return;
  const voxel_c *v = p->puzzle->getShape(s);
  *sx = v->getX(); *sy = v->getY(); *sz = v->getZ();
}

void bt_shape_resize(BTPuzzle *p, int s, int sx, int sy, int sz) {
  GUARD_BEGIN
  if (!validShape(p, s) || sx < 1 || sy < 1 || sz < 1) return;
  voxel_c *v = p->puzzle->getShape(s);
  v->resize(sx, sy, sz, voxel_c::VX_EMPTY);
  v->initHotspot();
  GUARD_END(nullptr, )
}

int bt_shape_voxel_count(BTPuzzle *p, int s) {
  if (!validShape(p, s)) return 0;
  const voxel_c *v = p->puzzle->getShape(s);
  return v->countState(voxel_c::VX_FILLED) + v->countState(voxel_c::VX_VARIABLE);
}

int bt_shape_get(BTPuzzle *p, int s, int x, int y, int z) {
  if (!validShape(p, s)) return 0;
  const voxel_c *v = p->puzzle->getShape(s);
  if (x < 0 || y < 0 || z < 0 || (unsigned)x >= v->getX() || (unsigned)y >= v->getY() || (unsigned)z >= v->getZ())
    return 0;
  if (!v->validCoordinate(x, y, z)) return 0;
  return v->getState(x, y, z);
}

void bt_shape_set(BTPuzzle *p, int s, int x, int y, int z, int state) {
  GUARD_BEGIN
  if (!validShape(p, s)) return;
  voxel_c *v = p->puzzle->getShape(s);
  if (x < 0 || y < 0 || z < 0 || (unsigned)x >= v->getX() || (unsigned)y >= v->getY() || (unsigned)z >= v->getZ())
    return;
  if (!v->validCoordinate(x, y, z)) return;
  v->setState(x, y, z, state);
  v->initHotspot();
  GUARD_END(nullptr, )
}

BTMesh *bt_shape_mesh(BTPuzzle *p, int s) {
  GUARD_BEGIN
  if (!validShape(p, s)) return 0;
  const voxel_c *v = p->puzzle->getShape(s);
  float cx, cy, cz;
  v->calculateSize(&cx, &cy, &cz);
  return meshFromVoxel(v, cx * 0.5f, cy * 0.5f, cz * 0.5f);
  GUARD_END(nullptr, nullptr)
}

/* ---- problems ---- */

int bt_problem_count(BTPuzzle *p) { return p ? (int)p->puzzle->getNumberOfProblems() : 0; }

int bt_problem_add(BTPuzzle *p) {
  GUARD_BEGIN
  return (int)p->puzzle->addProblem();
  GUARD_END(nullptr, -1)
}

void bt_problem_remove(BTPuzzle *p, int r) {
  GUARD_BEGIN
  if (validProblem(p, r)) p->puzzle->removeProblem(r);
  GUARD_END(nullptr, )
}

char *bt_problem_name(BTPuzzle *p, int r) {
  if (!validProblem(p, r)) return dupString("");
  return dupString(p->puzzle->getProblem(r)->getName());
}

void bt_problem_set_name(BTPuzzle *p, int r, const char *name) {
  if (validProblem(p, r)) p->puzzle->getProblem(r)->setName(name ? name : "");
}

int bt_problem_result(BTPuzzle *p, int r) {
  if (!validProblem(p, r)) return -1;
  problem_c *pr = p->puzzle->getProblem(r);
  return pr->resultValid() ? (int)pr->getResultId() : -1;
}

void bt_problem_set_result(BTPuzzle *p, int r, int s) {
  GUARD_BEGIN
  if (!validProblem(p, r)) return;
  problem_c *pr = p->puzzle->getProblem(r);
  if (validShape(p, s)) pr->setResultId(s); else pr->clearResult();
  GUARD_END(nullptr, )
}

void bt_problem_shape_count(BTPuzzle *p, int r, int s, int *mn, int *mx) {
  *mn = *mx = 0;
  if (!validProblem(p, r) || !validShape(p, s)) return;
  problem_c *pr = p->puzzle->getProblem(r);
  if (!pr->usesShape(s)) return;
  *mn = pr->getShapeMinimum(s);
  *mx = pr->getShapeMaximum(s);
}

void bt_problem_set_shape_count(BTPuzzle *p, int r, int s, int mn, int mx) {
  GUARD_BEGIN
  if (!validProblem(p, r) || !validShape(p, s)) return;
  if (mn < 0) mn = 0;
  if (mx < mn) mx = mn;
  problem_c *pr = p->puzzle->getProblem(r);
  // set the maximum first when growing, the minimum first when shrinking,
  // so min <= max always holds
  if (mx >= (int)pr->getShapeMaximum(s)) {
    pr->setShapeMaximum(s, mx);
    pr->setShapeMinimum(s, mn);
  } else {
    pr->setShapeMinimum(s, mn);
    pr->setShapeMaximum(s, mx);
  }
  GUARD_END(nullptr, )
}

int bt_problem_solve_state(BTPuzzle *p, int r) {
  if (!validProblem(p, r)) return BT_SOLVE_UNSOLVED;
  return (int)p->puzzle->getProblem(r)->getSolveState();
}

void bt_problem_stats(BTPuzzle *p, int r, long *a, long *s, long *t) {
  *a = *s = *t = -1;
  if (!validProblem(p, r)) return;
  problem_c *pr = p->puzzle->getProblem(r);
  if (pr->numAssembliesKnown()) *a = pr->getNumAssemblies();
  if (pr->numSolutionsKnown()) *s = pr->getNumSolutions();
  if (pr->usedTimeKnown()) *t = pr->getUsedTime();
}

int bt_problem_saved_solution_count(BTPuzzle *p, int r) {
  if (!validProblem(p, r)) return 0;
  return (int)p->puzzle->getProblem(r)->getNumberOfSavedSolutions();
}

void bt_problem_clear_solutions(BTPuzzle *p, int r) {
  GUARD_BEGIN
  if (validProblem(p, r)) p->puzzle->getProblem(r)->removeAllSolutions();
  GUARD_END(nullptr, )
}

/* ---- solutions ---- */

static solution_c *getSolution(BTPuzzle *p, int r, int s) {
  if (!validProblem(p, r)) return 0;
  problem_c *pr = p->puzzle->getProblem(r);
  if (s < 0 || (unsigned)s >= pr->getNumberOfSavedSolutions()) return 0;
  return pr->getSavedSolution(s);
}

int bt_solution_moves(BTPuzzle *p, int r, int s) {
  solution_c *so = getSolution(p, r, s);
  if (!so || !so->getDisassemblyInfo()) return -1;
  return (int)so->getDisassemblyInfo()->sumMoves();
}

char *bt_solution_moves_text(BTPuzzle *p, int r, int s) {
  solution_c *so = getSolution(p, r, s);
  if (!so || !so->getDisassemblyInfo()) return 0;
  char buf[200];
  buf[0] = 0;
  so->getDisassemblyInfo()->movesText(buf, sizeof(buf));
  return dupString(buf);
}

int bt_solution_number(BTPuzzle *p, int r, int s) {
  solution_c *so = getSolution(p, r, s);
  return so ? (int)so->getSolutionNumber() : 0;
}

int bt_solution_assembly_number(BTPuzzle *p, int r, int s) {
  solution_c *so = getSolution(p, r, s);
  return so ? (int)so->getAssemblyNumber() : 0;
}

/* ---- solver ---- */

BTSolver *bt_solver_start(BTPuzzle *p, int r, int flags, int sort, int limit, char **error) {
  GUARD_BEGIN
  if (!validProblem(p, r)) { setError(error, "No problem selected."); return 0; }
  if (!bt_puzzle_can_assemble(p)) { setError(error, "This grid type has no solver."); return 0; }
  if ((flags & BT_SOLVE_DISASSEMBLE) && !bt_puzzle_can_disassemble(p)) {
    setError(error, "This grid type has no disassembler. Turn off disassembly and try again.");
    return 0;
  }
  problem_c *pr = p->puzzle->getProblem(r);
  if (!pr->resultValid()) { setError(error, "Choose a result shape for this problem first."); return 0; }
  if (pr->getNumberOfParts() == 0) { setError(error, "Add at least one piece to this problem first."); return 0; }

  for (unsigned int i = 0; i < p->puzzle->getNumberOfShapes(); i++)
    p->puzzle->getShape(i)->initHotspot();

  solveThread_c *t = new solveThread_c(*pr, flags);
  t->setSortMethod(sort);
  // the solver has no "unlimited" setting (0 makes start() loop forever)
  t->setSolutionLimits(limit > 0 ? limit : (1u << 30), 1);
  if (!t->start(false)) {
    delete t;
    setError(error, "Could not start the solver thread.");
    return 0;
  }
  BTSolver *s = new BTSolver;
  s->thread = t;
  return s;
  GUARD_END(error, nullptr)
}

void bt_solver_status(BTSolver *s, BTSolverStatus *st) {
  memset(st, 0, sizeof(*st));
  st->progress = -1;
  st->assemblies = st->solutions = st->seconds = -1;
  try {
    solveThread_c *t = s->thread;
    st->action = t->currentAction();
    st->actionParameter = t->currentActionParameter();
    st->stopped = t->stopped() || st->action == BT_ACT_ASSERT;
    const problem_c &pr = t->getProblem();
    if (pr.numAssembliesKnown()) st->assemblies = pr.getNumAssemblies();
    if (pr.numSolutionsKnown()) st->solutions = pr.getNumSolutions();
    if (pr.usedTimeKnown()) st->seconds = pr.getUsedTime();
    if (!st->stopped) st->seconds = (st->seconds < 0 ? 0 : st->seconds) + t->getTime();
    if (pr.getAssembler()) st->progress = pr.getAssembler()->getFinished();
  } catch (...) {
    st->stopped = 1;
    st->action = BT_ACT_ASSERT;
  }
}

char *bt_solver_error(BTSolver *s) {
  solveThread_c *t = s->thread;
  if (t->currentAction() == solveThread_c::ACT_ASSERT)
    return dupString(describe(t->getAssertException()));
  if (t->currentAction() != solveThread_c::ACT_ERROR) return 0;

  int param = t->getErrorParam();
  switch (t->getErrorState()) {
  case assembler_c::ERR_TOO_MANY_UNITS:
    return dupString("The pieces have " + std::to_string(param) + " more cubes than the result shape can hold.");
  case assembler_c::ERR_TOO_FEW_UNITS:
    return dupString("The pieces have " + std::to_string(param) + " fewer cubes than the result shape needs.");
  case assembler_c::ERR_CAN_NOT_PLACE:
    return dupString("Piece " + std::to_string(param + 1) + " cannot be placed anywhere in the result shape.");
  case assembler_c::ERR_PUZZLE_UNHANDABLE:
    return dupString("This puzzle uses features the solver does not support.");
  case assembler_c::ERR_CAN_NOT_RESTORE_VERSION:
  case assembler_c::ERR_CAN_NOT_RESTORE_SYNTAX:
    return dupString("The saved solver state cannot be resumed. Clear the solutions and start again.");
  default:
    return dupString("The solver stopped with an error.");
  }
}

void bt_solver_stop(BTSolver *s) {
  try { s->thread->stop(); } catch (...) {}
}

void bt_solver_free(BTSolver *s) {
  if (!s) return;
  try {
    solveThread_c *t = s->thread;
    if (!t->stopped() && t->currentAction() != solveThread_c::ACT_ASSERT) {
      t->stop();
      while (!t->stopped() && t->currentAction() != solveThread_c::ACT_ASSERT)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    delete t;
  } catch (...) {}
  delete s;
}

/* ---- scene ---- */

BTScene *bt_scene_create(BTPuzzle *p, int r, int sol) {
  BTScene *sc = 0;
  try {
    solution_c *so = getSolution(p, r, sol);
    if (!so) return 0;
    problem_c *pr = p->puzzle->getProblem(r);
    const assembly_c *assm = so->getAssembly();
    const gridType_c *gt = p->puzzle->getGridType();

    sc = new BTScene;
    sc->moves = 0;
    sc->steps = 0;

    const voxel_c *result = getResultShape(*pr);
    result->calculateSize(&sc->cx, &sc->cy, &sc->cz);
    sc->cx *= 0.5f; sc->cy *= 0.5f; sc->cz *= 0.5f;

    unsigned int piece = 0;
    for (unsigned int part = 0; part < pr->getNumberOfParts(); part++)
      for (unsigned int q = 0; q < pr->getPartMaximum(part); q++) {
        BTScenePiece pc;
        pc.voxel = 0;
        pc.shape = pr->getShapeIdOfPart(part);
        pc.copy = q;
        pc.x = pc.y = pc.z = 0;
        pc.alpha = 0;
        if (assm->isPlaced(piece)) {
          voxel_c *vx = gt->getVoxel(pr->getPartShape(part));
          bt_assert2(vx->transform(assm->getTransformation(piece)));
          pc.voxel = vx;
          pc.x = assm->getX(piece);
          pc.y = assm->getY(piece);
          pc.z = assm->getZ(piece);
          pc.alpha = 1;
        }
        sc->pieces.push_back(pc);
        piece++;
      }

    if (so->getDisassembly()) {
      sc->moves = new disasmToMoves_c(so->getDisassembly(),
                                      2 * result->getBiggestDimension(),
                                      pr->getNumberOfPieces());
      sc->steps = so->getDisassembly()->sumMoves();
    }

    bt_scene_set_step(sc, 0);
    return sc;
  } catch (...) {
    bt_scene_free(sc);
    return 0;
  }
}

void bt_scene_free(BTScene *s) {
  if (!s) return;
  for (size_t i = 0; i < s->pieces.size(); i++) delete s->pieces[i].voxel;
  delete s->moves;
  delete s;
}

int bt_scene_piece_count(BTScene *s) { return (int)s->pieces.size(); }

BTMesh *bt_scene_piece_mesh(BTScene *s, int i) {
  if (i < 0 || (size_t)i >= s->pieces.size() || !s->pieces[i].voxel) return 0;
  try {
    const voxel_c *v = s->pieces[i].voxel;
    // the original renderer offsets each piece by its hotspot in space coordinates
    float hx = v->getHx(), hy = v->getHy(), hz = v->getHz();
    v->recalcSpaceCoordinates(&hx, &hy, &hz);
    return meshFromVoxel(v, hx, hy, hz);
  } catch (...) {
    return 0;
  }
}

void bt_scene_piece_info(BTScene *s, int i, int *shape, int *copy) {
  *shape = *copy = 0;
  if (i < 0 || (size_t)i >= s->pieces.size()) return;
  *shape = s->pieces[i].shape;
  *copy = s->pieces[i].copy;
}

int bt_scene_steps(BTScene *s) { return s->steps; }

void bt_scene_set_step(BTScene *s, float step) {
  if (!s->moves) return;
  try {
    s->moves->setStep(step, true, true);
    for (size_t i = 0; i < s->pieces.size(); i++) {
      BTScenePiece &pc = s->pieces[i];
      if (!pc.voxel) continue;
      pc.x = s->moves->getX(i);
      pc.y = s->moves->getY(i);
      pc.z = s->moves->getZ(i);
      pc.alpha = s->moves->getA(i);
    }
  } catch (...) {}
}

void bt_scene_piece_position(BTScene *s, int i, float *x, float *y, float *z, float *alpha) {
  *x = *y = *z = 0;
  *alpha = 0;
  if (i < 0 || (size_t)i >= s->pieces.size()) return;
  BTScenePiece &pc = s->pieces[i];
  if (!pc.voxel) return;
  float px = pc.x, py = pc.y, pz = pc.z;
  pc.voxel->recalcSpaceCoordinates(&px, &py, &pz);
  *x = px - s->cx;
  *y = py - s->cy;
  *z = pz - s->cz;
  *alpha = pc.alpha;
}

/* ---- STL export ---- */

struct BTStl {
  stlExporter_c *exporter;
};

void bt_shape_extent(BTPuzzle *p, int s, float *x, float *y, float *z) {
  *x = *y = *z = 0;
  if (!validShape(p, s)) return;
  try {
    Polyhedron *poly = p->puzzle->getShape(s)->getDrawingMesh();
    if (!poly) return;
    bool first = true;
    float mn[3] = {0, 0, 0}, mx[3] = {0, 0, 0};
    for (Polyhedron::const_vertex_iterator it = poly->vBegin(); it != poly->vEnd(); ++it) {
      const Vector3Df &v = (*it)->position();
      for (int i = 0; i < 3; i++) {
        if (first || v[i] < mn[i]) mn[i] = v[i];
        if (first || v[i] > mx[i]) mx[i] = v[i];
      }
      first = false;
    }
    delete poly;
    *x = mx[0] - mn[0];
    *y = mx[1] - mn[1];
    *z = mx[2] - mn[2];
  } catch (...) {}
}

int bt_puzzle_can_export_stl(BTPuzzle *p) {
  return (p->puzzle->getGridType()->getCapabilities() & gridType_c::CAP_STLEXPORT) ? 1 : 0;
}

BTStl *bt_stl_create(BTPuzzle *p) {
  if (!bt_puzzle_can_export_stl(p)) return 0;
  try {
    stlExporter_c *e = p->puzzle->getGridType()->getStlExporter();
    if (!e) return 0;
    BTStl *s = new BTStl;
    s->exporter = e;
    return s;
  } catch (...) {
    return 0;
  }
}

void bt_stl_free(BTStl *s) {
  if (!s) return;
  delete s->exporter;
  delete s;
}

static bool validParam(BTStl *s, int i) { return s && i >= 0 && (unsigned)i < s->exporter->numParameters(); }

int bt_stl_param_count(BTStl *s) { return s ? (int)s->exporter->numParameters() : 0; }

char *bt_stl_param_name(BTStl *s, int i) {
  const char *n = validParam(s, i) ? s->exporter->getParameterName(i) : 0;
  return dupString(n ? n : "");
}

char *bt_stl_param_tooltip(BTStl *s, int i) {
  const char *n = validParam(s, i) ? s->exporter->getParameterTooltip(i) : 0;
  return dupString(n ? n : "");
}

int bt_stl_param_type(BTStl *s, int i) { return validParam(s, i) ? (int)s->exporter->getParameterType(i) : 0; }
double bt_stl_param_get(BTStl *s, int i) { return validParam(s, i) ? s->exporter->getParameter(i) : 0; }
void bt_stl_param_set(BTStl *s, int i, double v) { if (validParam(s, i)) s->exporter->setParameter(i, v); }
void bt_stl_set_binary(BTStl *s, int b) { if (s) s->exporter->setBinaryMode(b != 0); }

BTMesh *bt_stl_mesh(BTStl *s, BTPuzzle *p, int shape, char **error) {
  if (!s || !validShape(p, shape)) { setError(error, "No shape selected."); return 0; }
  try {
    faceList_c holes;
    Polyhedron *poly = s->exporter->getMesh(*p->puzzle->getShape(shape), holes);
    if (!poly) { setError(error, "Could not create the mesh."); return 0; }
    BTMesh *m = meshFromPolyhedron(poly, 0, 0, 0);
    delete poly;
    if (!m) setError(error, "The shape is empty.");
    return m;
  }
  catch (stlException_c &e) { setError(error, e.comment ? e.comment : "Could not create the mesh."); }
  catch (assert_exception &e) { setError(error, describe(e)); }
  catch (...) { setError(error, "The mesh could not be created with these settings. Try a smaller bevel or clearance."); }
  return 0;
}

int bt_stl_write(BTStl *s, BTPuzzle *p, int shape, const char *path, char **error) {
  if (!s || !validShape(p, shape)) { setError(error, "No shape selected."); return 0; }
  if (bt_shape_voxel_count(p, shape) == 0) { setError(error, "The shape is empty."); return 0; }
  try {
    faceList_c holes;
    s->exporter->write(path, *p->puzzle->getShape(shape), holes);
    return 1;
  }
  catch (stlException_c &e) { setError(error, e.comment ? e.comment : "Could not write the STL file."); }
  catch (assert_exception &e) { setError(error, describe(e)); }
  catch (...) { setError(error, "The mesh could not be created with these settings. Try a smaller bevel or clearance."); }
  return 0;
}
