;; Binds every xref and saves the result as the plan's target ("<source>|<target>").
;; The source drawing is never saved. Nothing is written unless all xrefs could be bound.
;; Unresolved xrefs are reloaded once; if one still fails it is reported and the export stops.
;; If "bind all" fails (proxy objects, self references...) each xref is retried alone,
;; first as Bind and then as Insert.

(defun bind-export (planfile blk outfile / o op dst bt bad l)
  (setq op (car (adt-plan planfile)) o (open outfile "w") bt (getvar "BINDTYPE"))
  (if op (setq dst (car op)))
  (cond
    ((not dst) (write-line "NOPLAN" o))
    ((findfile dst) (write-line (strcat "EXISTS|" dst) o))
    ((and (/= blk "") (not (ssget "_X" (list (cons 0 "INSERT") (cons 2 blk))))) (write-line "NOTITLEBLOCK" o))
    (T
      (foreach nm (adt-xrefs)
        (if (not (adt-resolved nm))
          (progn
            (command "_.-XREF" "_R" nm)
            (if (adt-resolved nm) (write-line (strcat "RELOADED|" nm) o) (setq bad (cons nm bad))))))
      (if bad
        (foreach nm bad (write-line (strcat "UNRESOLVED|" nm) o))
        (progn
          (write-line (strcat "XREFS|" (itoa (adt-xrefcount))) o)
          (command "_.-XREF" "_B" "*")
          (if (> (adt-xrefcount) 0)
            (foreach nm (adt-xrefs)
              (setvar "BINDTYPE" 0)
              (command "_.-XREF" "_B" nm)
              (if (adt-isxref nm) (progn (setvar "BINDTYPE" 1) (command "_.-XREF" "_B" nm)))
              (if (adt-isxref nm) (write-line (strcat "BINDFAILED|" nm) o))))
          (setvar "BINDTYPE" bt)
          (if (= 0 (adt-xrefcount))
            (progn
              (if (setq l (adt-sheet-layout blk)) (setvar "CTAB" l))
              (command "_.SAVEAS" "" dst)
              (write-line (strcat "SAVED|" (if (findfile dst) "OK" "FAIL")) o))
            (write-line "NOTSAVED" o))))))
  (close o)
  (princ))
