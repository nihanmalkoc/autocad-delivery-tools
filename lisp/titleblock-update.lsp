;; Sets title block attributes, e.g. (titleblock-update "TITLEBLOCK" '(("DATE" . "30.07.2026") ("REVNO" . "00_0")) out)
;; Fields (file name, sheet name) are left alone; the sheet layout is made current before saving
;; so that layout-based fields are cached with the right value.

(defun titleblock-update (blk pairs outfile / f ss i e a ad v n l)
  (setq f (open outfile "w") n 0)
  (if (setq ss (ssget "_X" (list (cons 0 "INSERT") (cons 2 blk))))
    (progn
      (setq i 0)
      (repeat (sslength ss)
        (setq e (ssname ss i) i (1+ i) a (entnext e))
        (while (and a (= "ATTRIB" (cdr (assoc 0 (setq ad (entget a))))))
          (if (setq v (cdr (assoc (strcase (cdr (assoc 2 ad))) pairs)))
            (progn
              (write-line (strcat (cdr (assoc 2 ad)) "|" (cdr (assoc 1 ad)) "|" v) f)
              (entmod (subst (cons 1 v) (assoc 1 ad) ad))
              (setq n (1+ n))))
          (setq a (entnext a)))
        (entupd e))
      (if (setq l (adt-sheet-layout blk)) (setvar "CTAB" l))
      (if (> n 0) (command "_.QSAVE")))
    (write-line "NOBLOCK" f))
  (write-line (strcat "END|" (itoa n)) f)
  (close f)
  (princ))
