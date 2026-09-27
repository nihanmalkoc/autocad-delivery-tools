;; One line per paper space layout name.

(defun layout-report (outfile / f)
  (setq f (open outfile "w"))
  (foreach e (dictsearch (namedobjdict) "ACAD_LAYOUT")
    (if (and (= (car e) 3) (/= (strcase (cdr e)) "MODEL")) (write-line (cdr e) f)))
  (close f)
  (princ))
