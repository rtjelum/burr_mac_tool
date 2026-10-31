/* C interface to the BurrTools library, used by the Swift app.
 *
 * All functions catch C++ exceptions, so they never throw. Strings returned
 * as `char *` are allocated with malloc and must be released with bt_free.
 */
#ifndef BURRBRIDGE_H
#define BURRBRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BTPuzzle BTPuzzle;
typedef struct BTSolver BTSolver;
typedef struct BTScene BTScene;

/* A triangle mesh: 3 floats per vertex, 3 vertices per triangle.
 * `light` holds one flag per triangle (checkerboard shading). */
typedef struct {
  int triangleCount;
  float *positions;
  float *normals;
  unsigned char *light;
  unsigned char *variable;
} BTMesh;

void bt_free(void *ptr);
void bt_mesh_free(BTMesh *mesh);

/* ---- puzzle ---- */
enum { BT_GRID_BRICKS = 0, BT_GRID_TRIANGULAR_PRISM, BT_GRID_SPHERES, BT_GRID_RHOMBIC, BT_GRID_TETRA_OCTA };

BTPuzzle *bt_puzzle_new(int gridType);
BTPuzzle *bt_puzzle_load(const char *path, char **error);
int bt_puzzle_save(BTPuzzle *p, const char *path, char **error);
void bt_puzzle_free(BTPuzzle *p);

int bt_puzzle_grid_type(BTPuzzle *p);
int bt_puzzle_can_assemble(BTPuzzle *p);
int bt_puzzle_can_disassemble(BTPuzzle *p);
char *bt_puzzle_comment(BTPuzzle *p);
void bt_puzzle_set_comment(BTPuzzle *p, const char *comment);

/* ---- shapes ---- */
enum { BT_VOXEL_EMPTY = 0, BT_VOXEL_FILLED = 1, BT_VOXEL_VARIABLE = 2 };

int bt_shape_count(BTPuzzle *p);
int bt_shape_add(BTPuzzle *p, int sx, int sy, int sz);
void bt_shape_remove(BTPuzzle *p, int shape);
char *bt_shape_name(BTPuzzle *p, int shape);
void bt_shape_set_name(BTPuzzle *p, int shape, const char *name);
void bt_shape_size(BTPuzzle *p, int shape, int *sx, int *sy, int *sz);
void bt_shape_resize(BTPuzzle *p, int shape, int sx, int sy, int sz);
int bt_shape_voxel_count(BTPuzzle *p, int shape);
int bt_shape_get(BTPuzzle *p, int shape, int x, int y, int z);
void bt_shape_set(BTPuzzle *p, int shape, int x, int y, int z, int state);
/* Whole-shape fill tools. "Inside" voxels have no empty neighbour, "outside"
 * voxels are the filled ones on the surface. */
enum {
  BT_TOOL_FILL_ALL = 0,       /* every voxel filled */
  BT_TOOL_CLEAR_ALL,          /* every voxel empty */
  BT_TOOL_INSIDE_VARIABLE,    /* e.g. a box whose centre may stay empty */
  BT_TOOL_INSIDE_FILLED,
  BT_TOOL_INSIDE_EMPTY,       /* hollow out */
  BT_TOOL_OUTSIDE_VARIABLE,
  BT_TOOL_OUTSIDE_FILLED,
  BT_TOOL_ALL_VARIABLE,       /* every non-empty voxel variable */
  BT_TOOL_ALL_FILLED,         /* every non-empty voxel filled */
  BT_TOOL_FILL_HOLES          /* fill empty voxels enclosed by the shape */
};
void bt_shape_tool(BTPuzzle *p, int shape, int tool);
/* Mesh of a shape, centred on the origin. NULL if the shape is empty. */
BTMesh *bt_shape_mesh(BTPuzzle *p, int shape);

/* ---- problems ---- */
int bt_problem_count(BTPuzzle *p);
int bt_problem_add(BTPuzzle *p);
void bt_problem_remove(BTPuzzle *p, int prob);
char *bt_problem_name(BTPuzzle *p, int prob);
void bt_problem_set_name(BTPuzzle *p, int prob, const char *name);
/* -1 if no result shape is set */
int bt_problem_result(BTPuzzle *p, int prob);
void bt_problem_set_result(BTPuzzle *p, int prob, int shape);
/* How many copies of `shape` the problem uses (0 = not used). */
void bt_problem_shape_count(BTPuzzle *p, int prob, int shape, int *min, int *max);
void bt_problem_set_shape_count(BTPuzzle *p, int prob, int shape, int min, int max);

/* Maximum number of empty variable voxels allowed in a solution; -1 = no limit. */
int bt_problem_max_holes(BTPuzzle *p, int prob);
void bt_problem_set_max_holes(BTPuzzle *p, int prob, int holes);

enum { BT_SOLVE_UNSOLVED = 0, BT_SOLVE_SOLVING, BT_SOLVE_SOLVED, BT_SOLVE_UNKNOWN };
int bt_problem_solve_state(BTPuzzle *p, int prob);
/* Fields are -1 when not known. */
void bt_problem_stats(BTPuzzle *p, int prob, long *assemblies, long *solutions, long *seconds);
int bt_problem_saved_solution_count(BTPuzzle *p, int prob);
void bt_problem_clear_solutions(BTPuzzle *p, int prob);

/* ---- solutions ---- */
/* Moves needed to disassemble (-1 if no disassembly is stored). */
int bt_solution_moves(BTPuzzle *p, int prob, int sol);
/* Moves summary like "5.3.1", or NULL. */
char *bt_solution_moves_text(BTPuzzle *p, int prob, int sol);
int bt_solution_number(BTPuzzle *p, int prob, int sol);
int bt_solution_assembly_number(BTPuzzle *p, int prob, int sol);

/* ---- solver ---- */
enum {
  BT_SOLVE_REDUCE = 0x01,
  BT_SOLVE_KEEP_MIRROR = 0x02,
  BT_SOLVE_KEEP_ROTATIONS = 0x04,
  BT_SOLVE_DROP_DISASSEMBLIES = 0x08,
  BT_SOLVE_DISASSEMBLE = 0x10,
  BT_SOLVE_JUST_COUNT = 0x20,
  BT_SOLVE_COMPLETE_ROTATIONS = 0x40
};
enum { BT_SORT_NONE = 0, BT_SORT_MOVES, BT_SORT_LEVEL };
enum {
  BT_ACT_PREPARATION = 0, BT_ACT_REDUCE, BT_ACT_ASSEMBLING, BT_ACT_DISASSEMBLING,
  BT_ACT_PAUSING, BT_ACT_FINISHED, BT_ACT_ERROR, BT_ACT_ASSERT, BT_ACT_WAIT_TO_STOP
};

/* Returns NULL and sets *error if solving cannot start. While a solver
 * exists, the puzzle must not be changed or read from other threads except
 * through bt_solver_status. */
BTSolver *bt_solver_start(BTPuzzle *p, int prob, int flags, int sort, int limit, char **error);
typedef struct {
  int action;
  int actionParameter;
  long assemblies;
  long solutions;
  long seconds;
  double progress; /* 0..1, or -1 if unknown */
  int stopped;
} BTSolverStatus;
void bt_solver_status(BTSolver *s, BTSolverStatus *status);
/* Error message if the solver ended in an error state, else NULL. */
char *bt_solver_error(BTSolver *s);
void bt_solver_stop(BTSolver *s);
/* Stops (and waits for) the solver thread, then frees it. */
void bt_solver_free(BTSolver *s);

/* ---- 3D scene of a solution, with disassembly animation ---- */
BTScene *bt_scene_create(BTPuzzle *p, int prob, int sol);
void bt_scene_free(BTScene *s);
int bt_scene_piece_count(BTScene *s);
/* Mesh of piece i in its own coordinates (NULL if the piece is not placed). */
BTMesh *bt_scene_piece_mesh(BTScene *s, int piece);
/* Like bt_scene_piece_mesh but with rounded (bevelled) edges and faces set
 * back by `offset`, both in grid units (e.g. 0.12 and 0.01). Falls back to the
 * drawing mesh if that fails. */
BTMesh *bt_scene_piece_mesh_bevelled(BTScene *s, int piece, double bevel, double offset);
/* Shape id and copy number of piece i, for colouring. */
void bt_scene_piece_info(BTScene *s, int piece, int *shape, int *copy);
/* Total animation steps (0 if there is no disassembly). */
int bt_scene_steps(BTScene *s);
/* Moves the pieces to animation position `step` (0..steps, fractional allowed). */
void bt_scene_set_step(BTScene *s, float step);
/* Filled voxels of piece i as x,y,z triples (the voxel's low corner) in the
 * same local coordinates as bt_scene_piece_mesh. Returns the voxel count and a
 * malloc'ed array in *out (free with bt_free). Meant for cube grids. */
int bt_scene_piece_voxels(BTScene *s, int piece, float **out);
/* Current position of piece i, already centred on the assembled puzzle. */
void bt_scene_piece_position(BTScene *s, int piece, float *x, float *y, float *z, float *alpha);

/* ---- STL export ---- */
typedef struct BTStl BTStl;
enum { BT_STL_DOUBLE = 0, BT_STL_POS_DOUBLE, BT_STL_POS_INTEGER, BT_STL_SWITCH };

/* Size of a shape in grid drawing units (the 3D extent of its filled voxels).
 * Multiply by the unit size (cube grids) or 2 x sphere radius (sphere grid)
 * to get millimetres. */
void bt_shape_extent(BTPuzzle *p, int shape, float *x, float *y, float *z);

int bt_puzzle_can_export_stl(BTPuzzle *p);
/* NULL if this grid type has no STL exporter. */
BTStl *bt_stl_create(BTPuzzle *p);
void bt_stl_free(BTStl *s);
int bt_stl_param_count(BTStl *s);
char *bt_stl_param_name(BTStl *s, int idx);
char *bt_stl_param_tooltip(BTStl *s, int idx);
int bt_stl_param_type(BTStl *s, int idx);
double bt_stl_param_get(BTStl *s, int idx);
void bt_stl_param_set(BTStl *s, int idx, double value);
void bt_stl_set_binary(BTStl *s, int binary);
/* The mesh that would be exported, in millimetres. NULL and *error on failure. */
BTMesh *bt_stl_mesh(BTStl *s, BTPuzzle *p, int shape, char **error);
int bt_stl_write(BTStl *s, BTPuzzle *p, int shape, const char *path, char **error);

/* ---- puzzle generator ---- */
typedef struct BTGenerator BTGenerator;
typedef struct {
  long tried;          /* designs checked */
  long valid;          /* designs that met the solution rule */
  int running;
  int found;           /* a design reached the target */
  int haveBest;
  int bestLevel;       /* moves until the first piece comes out */
  int bestMoves;       /* moves for the whole disassembly */
  int bestSolutions;
} BTGeneratorStatus;

/* Splits `shape` (its filled cubes) into `pieces` connected pieces of at least
 * `minSize` cubes, searching in the background for a design whose level
 * (metric 0) or total moves (metric 1) reaches `target`. With `unique`, only
 * designs with exactly one solution count. seed 0 = random. */
BTGenerator *bt_generator_start(BTPuzzle *p, int shape, int pieces, int target, int metric,
                                int unique, int minSize, unsigned int seed, char **error);
void bt_generator_status(BTGenerator *g, BTGeneratorStatus *status);
char *bt_generator_error(BTGenerator *g);
void bt_generator_stop(BTGenerator *g);
/* Stops the search (waits for it) and frees the generator. */
void bt_generator_free(BTGenerator *g);
/* Best design so far as one piece number per voxel of the result shape (-1 =
 * not part of a piece). Returns 0 if there is none yet. */
int bt_generator_best(BTGenerator *g, int *out, int count);
/* Adds the best design to the puzzle as new shapes and a new problem using
 * `resultShape`. Returns the new problem index, or -1. */
int bt_generator_add_best(BTGenerator *g, BTPuzzle *p, int resultShape);

#ifdef __cplusplus
}
#endif

#endif
