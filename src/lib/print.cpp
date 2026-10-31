/* BurrTools
 *
 * BurrTools is the legal property of its developers, whose
 * names are listed in the COPYRIGHT file, which is included
 * within the source distribution.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 */
#include "print.h"

#include "voxel.h"
#include "puzzle.h"
#include "problem.h"
#include "disassembly.h"
#include "assembly.h"
#include "assert.h"

void print(const voxel_c * v, char base) {
  for (unsigned int z = 0; z < v->getZ(); z++) {
    printf(" +");
    for (unsigned int x = 0; x < v->getX(); x++)
      printf("-");
    printf("+");
  }
  printf(" bx %i-%i by %i-%i bz %i-%i h: %i %i %i \n", v->boundX1(), v->boundX2(), v->boundY1(), v->boundY2(), v->boundZ1(), v->boundZ2(), v->getHx(), v->getHy(), v->getHz());

  for (unsigned int y = 0; y < v->getY(); y++) {
    for (unsigned int z = 0; z < v->getZ(); z++) {
      printf(" !");
      for (unsigned int x = 0; x < v->getX(); x++)
        if (v->get(x, y, z) != 0)
          printf("%c", base + v->get(x, y, z)-1);
        else
          printf(" ");
      printf("!");
    }
    printf("\n");
  }

  { for (unsigned int z = 0; z < v->getZ(); z++) {
      printf(" +");
      for (unsigned int x = 0; x < v->getX(); x++)
        printf("-");
      printf("+");
    }
  }
  printf("\n");
}

void print(const puzzle_c * p) {

  for (unsigned int s = 0; s < p->getNumberOfShapes(); s++) {
    printf("shape %i:\n", s);
    print(p->getShape(s));
  }

  printf("=======================================================\n");

  for (unsigned int pr = 0; pr < p->getNumberOfProblems(); pr++) {

    const problem_c * prob = p->getProblem(pr);

    printf("problem %i (%s):\n", pr, prob->getName().c_str());
    if (!prob->resultValid())
      printf(" result shape: not defined\n");
    else
      printf(" result shape: %i\n", prob->getResultId());

    for (unsigned int sh = 0; sh < prob->getNumberOfParts(); sh++)
      if (prob->getPartMinimum(sh) != prob->getPartMaximum(sh))
        printf(" piece shape: %i-%i times shape number %i\n", prob->getPartMinimum(sh), prob->getPartMaximum(sh), prob->getShapeIdOfPart(sh));
      else if (prob->getPartMinimum(sh) != 1)
        printf(" piece shape: %i times shape number %i\n", prob->getPartMinimum(sh), prob->getShapeIdOfPart(sh));
      else
        printf(" piece shape: %i\n", prob->getShapeIdOfPart(sh));

    printf("-------------------------------------------------------\n");
  }
}

static void print_rec(const separation_c * s, voxel_c ** pieces, int sx, int sy, int sz, unsigned int * pieceNum) {

  for (unsigned int i = 0; i <= s->getMoves(); i++) {

    const state_c * st = s->getState(i);

    for (int z = -sz; z < sz+sz; z++) {
      printf(" +");
      for (int x = -sx; x < sx+sx; x++)
        printf("-");
      printf("+");
    }
    printf("\n");

    for (int y = -sy; y < sy+sy; y++) {
      for (int z = -sz; z < sz+sz; z++) {
        printf(" !");
        for (int x = -sx; x < sx+sx; x++) {
          char c = ' ';

          for (unsigned int pc = 0; pc < s->getPieceNumber(); pc++)
            if (pieces[pc]->isFilled2(x - (st->getX(pc) - pieces[pc]->getHx()),
                                      y - (st->getY(pc) - pieces[pc]->getHy()),
                                      z - (st->getZ(pc) - pieces[pc]->getHz()))) {
              c = 'a' + pieceNum[pc];
              break;
            }

          printf("%c", c);
        }
        printf("!");
      }
      printf("\n");
    }

    { for (int z = -sz; z < sz+sz; z++) {
        printf(" +");
        for (int x = -sx; x < sx+sx; x++)
          printf("-");
        printf("+");
      }
    }
    printf("\n");
  }

  printf(" puzzle separates into  2 parts\n");

  if (s->getRemoved()) {

    unsigned int removedCount = 0;
    for (unsigned int i = 0; i < s->getPieceNumber(); i++)
      if (s->getState(s->getMoves())->pieceRemoved(i))
        removedCount++;

    voxel_c ** pieces2 = new voxel_c*[removedCount];
    unsigned int * pieceNum2 = new unsigned int[removedCount];

    int pos = 0;
    for (unsigned int i = 0; i < s->getPieceNumber(); i++)
      if (s->getState(s->getMoves())->pieceRemoved(i)) {
        pieces2[pos] = pieces[i];
        pieceNum2[pos] = pieceNum[i];
        pos++;
      }

    print_rec(s->getRemoved(), pieces2, sx, sy, sz, pieceNum2);

    delete [] pieces2;
    delete [] pieceNum2;
  }
  if (s->getLeft()) {

    unsigned int leftCount = 0;
    for (unsigned int i = 0; i < s->getPieceNumber(); i++)
      if (!s->getState(s->getMoves())->pieceRemoved(i))
        leftCount++;

    voxel_c ** pieces2 = new voxel_c*[leftCount];
    unsigned int * pieceNum2 = new unsigned int[leftCount];

    int pos = 0;
    for (unsigned int i = 0; i < s->getPieceNumber(); i++)
      if (!s->getState(s->getMoves())->pieceRemoved(i)) {
        pieces2[pos] = pieces[i];
        pieceNum2[pos] = pieceNum[i];
        pos++;
      }

    print_rec(s->getLeft(), pieces2, sx, sy, sz, pieceNum2);

    delete [] pieces2;
    delete [] pieceNum2;
  }
}

void print(const separation_c * s, const assembly_c * a, const problem_c * p) {

  bt_assert(p->resultValid());

  const voxel_c * res = getResultShape(*p);

  // Only include placed pieces — unplaced ones have no transformation and would crash.
  // The separation indexes pieces in the same order as placed slots in the assembly.
  voxel_c ** pieces = new voxel_c*[s->getPieceNumber()];

  unsigned int pc = 0;
  unsigned int sep_pc = 0;

  for (unsigned int i = 0; i < p->getNumberOfParts(); i++)
    for (unsigned int j = 0; j < p->getPartMaximum(i); j++) {

      if (a->isPlaced(pc)) {
        pieces[sep_pc] = p->getPuzzle().getGridType()->getVoxel(p->getPartShape(i));
        bt_assert2(pieces[sep_pc]->transform(a->getTransformation(pc)));
        sep_pc++;
      }
      pc++;
    }

  bt_assert(sep_pc == s->getPieceNumber());

  unsigned int * pieceNum = new unsigned int [s->getPieceNumber()];
  for (unsigned int i = 0; i < s->getPieceNumber(); i++)
    pieceNum[i] = i;

  print_rec(s, pieces, res->getX(), res->getY(), res->getZ(), pieceNum);

  for (unsigned int i = 0; i < s->getPieceNumber(); i++)
    delete pieces[i];

  delete [] pieceNum;
  delete [] pieces;
}

void print(const assembly_c * a, const problem_c * p) {

  bt_assert(p->resultValid());

  const voxel_c * res = getResultShape(*p);

  voxel_c ** pieces = new voxel_c*[a->placementCount()];

  unsigned int pc = 0;

  for (unsigned int i = 0; i < p->getNumberOfParts(); i++)
    for (unsigned int j = 0; j < p->getPartMaximum(i); j++) {

      if (a->isPlaced(pc)) {
        pieces[pc] = p->getPuzzle().getGridType()->getVoxel(p->getPartShape(i));
        bt_assert2(pieces[pc]->transform(a->getTransformation(pc)));
      } else
        pieces[pc] = 0;

      pc++;
    }

  for (unsigned int z = 0; z < res->getZ(); z++) {
    printf(" +");
    for (unsigned int x = 0; x < res->getX(); x++)
      printf("-");
    printf("+");
  }
  printf("\n");

  for (unsigned int y = 0; y < res->getY(); y++) {
    for (unsigned int z = 0; z < res->getZ(); z++) {
      printf(" !");
      for (unsigned int x = 0; x < res->getX(); x++) {
        char c = ' ';

        unsigned int pc = 0;

        for (unsigned int p = 0; p < a->placementCount(); p++)

          if (a->isPlaced(p)) {

            if (pieces[p]->isFilled2(x - (a->getX(p) - pieces[p]->getHx()),
                                     y - (a->getY(p) - pieces[p]->getHy()),
                                     z - (a->getZ(p) - pieces[p]->getHz()))) {
              c = 'a' + pc;
              break;
            }

            pc++;
          }

        printf("%c", c);
      }
      printf("!");
    }
    printf("\n");
  }

  { for (unsigned int z = 0; z < res->getZ(); z++) {
      printf(" +");
      for (unsigned int x = 0; x < res->getX(); x++)
        printf("-");
      printf("+");
    }
  }
  printf("\n");

  for (unsigned int pc = 0; pc < a->placementCount(); pc++)
    if (pieces[pc])
      delete pieces[pc];

  delete [] pieces;
}
