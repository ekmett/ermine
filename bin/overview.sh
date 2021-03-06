#!/bin/sh
find src -name "*.hs" -print | xargs graphmod --no-cluster -C Ermine.Syntax -C Ermine.Pretty -C Ermine.Inference -C Ermine.Unification -C Ermine.Parser -C Ermine.Console -C Ermine.Binary -C Ermine.Pattern -C Ermine.Constraint -C Ermine.Monitor -C Ermine.Core -C Ermine.Builtin -r Main | dot -Tpng > etc/overview.png
