;; Applies plan ops to the current drawing and saves it when anything changed.
;;   DET|xref            detach (retried once at the end: nested references block the first try)
;;   DUP|xref            erase all but the first insert of the xref
;;   ATT|relative path   overlay at 0,0,0, scale 1, rotation 0, layer 0, model space, relative path
;;   PATH|xref|relative path|new name   repoint an xref and rename it
;;   DRAW|TOP|REF1,REF2  bring the TOP xref above the REF xrefs (types are file name tokens)

(defun set-fix (planfile outfile / o ops ss i tm cl dir ab bn dr rf n)
  (setq ops (adt-plan planfile) dir (getvar "DWGPREFIX") n 0 o (open outfile "w"))
  (setq tm (getvar "TILEMODE") cl (getvar "CLAYER"))
  (setvar "TILEMODE" 1)
  (setvar "CLAYER" "0")
  (foreach op ops
    (cond
      ((= (car op) "DET")
        (if (tblsearch "BLOCK" (cadr op))
          (progn (command "_.-XREF" "_D" (cadr op)) (setq n (1+ n))
                 (write-line (strcat "DET|" (cadr op) "|" (if (tblsearch "BLOCK" (cadr op)) "RETRY" "OK")) o))
          (write-line (strcat "DET|" (cadr op) "|NOBLOCK") o)))
      ((= (car op) "DUP")
        (setq ss (ssget "_X" (list (cons 0 "INSERT") (cons 2 (cadr op)))) i 1)
        (if (and ss (> (sslength ss) 1))
          (progn (repeat (1- (sslength ss)) (entdel (ssname ss i)) (setq i (1+ i)))
                 (setq n (1+ n)) (write-line (strcat "DUP|" (cadr op) "|OK") o))
          (write-line (strcat "DUP|" (cadr op) "|SKIP") o)))
      ((= (car op) "ATT")
        (setq ab (findfile (strcat dir (cadr op))))
        (setq bn (adt-fname (cadr op)) bn (substr bn 1 (- (strlen bn) 4)))
        (cond
          ((not ab) (write-line (strcat "ATT|" (cadr op) "|NOFILE") o))
          ((tblsearch "BLOCK" bn) (write-line (strcat "ATT|" bn "|NAMEEXISTS") o))
          (T
            (command "_.-XREF" "_O" ab "0,0,0" "1" "1" "0")
            (if (tblsearch "BLOCK" bn) (command "_.-XREF" "_P" bn (cadr op)))
            (setq n (1+ n))
            (write-line (strcat "ATT|" bn "|" (if (ssget "_X" (list (cons 0 "INSERT") (cons 2 bn))) "OK" "FAIL")) o))))
      ((= (car op) "PATH")
        (cond
          ((not (tblsearch "BLOCK" (cadr op))) (write-line (strcat "PATH|" (cadr op) "|NOBLOCK") o))
          ((not (findfile (strcat dir (caddr op)))) (write-line (strcat "PATH|" (cadr op) "|NOFILE|" (caddr op)) o))
          (T
            (command "_.-XREF" "_P" (cadr op) (caddr op))
            (if (and (/= (strcase (cadr op)) (strcase (cadddr op))) (not (tblsearch "BLOCK" (cadddr op))))
              (command "_.-RENAME" "_B" (cadr op) (cadddr op)))
            (setq n (1+ n))
            (write-line (strcat "PATH|" (cadr op) "|" (cadddr op) "|" (if (tblsearch "BLOCK" (cadddr op)) "OK" "FAIL")) o))))
      ((= (car op) "DRAW")
        (setq dr (adt-xref-inserts (adt-type-pattern (cadr op))) rf (adt-xref-inserts (adt-type-pattern (caddr op))))
        (if (and (> (sslength dr) 0) (> (sslength rf) 0))
          (progn (command "_.DRAWORDER" dr "" "_A" rf "") (setq n (1+ n)) (write-line "DRAW|OK" o))
          (write-line "DRAW|SKIP" o)))))
  (foreach op ops
    (if (and (= (car op) "DET") (tblsearch "BLOCK" (cadr op)))
      (progn (command "_.-XREF" "_D" (cadr op))
             (write-line (strcat "DET2|" (cadr op) "|" (if (tblsearch "BLOCK" (cadr op)) "FAIL" "OK")) o))))
  (setvar "CLAYER" cl)
  (setvar "TILEMODE" tm)
  (if (> n 0) (command "_.QSAVE"))
  (write-line (strcat "END|" (itoa n)) o)
  (close o)
  (princ))
