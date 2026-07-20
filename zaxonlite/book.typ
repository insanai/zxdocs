#import "book/theme.typ": *

#show: book

#include "book/00_front.typ"
#{
  // Front matter: the reading guide stays outside the chapter numbering so
  // that rendered chapter numbers match the book's own cross-references.
  set heading(numbering: none)
  include "book/00_learning.typ"
}
#include "book/01_quickstart.typ"
#include "book/02_cli.typ"
#include "book/03_product.typ"
#include "book/04_architecture.typ"
#include "book/05_wal.typ"
#include "book/06_storage.typ"
#include "book/07_cluster.typ"
#include "book/08_consistency.typ"
#include "book/09_embed_node.typ"
#include "book/10_embed_cluster.typ"
#include "book/11_c_abi.typ"
#include "book/12_client_gateway.typ"
#include "book/13_operations.typ"
#include "book/14_examples.typ"
#include "book/15_formats.typ"
#include "book/16_reference.typ"
#include "book/17_verification.typ"
#include "book/18_conformance.typ"
