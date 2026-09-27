;; Renames the single paper space layout to the drawing name without the prefix and extension.
;; Drawings with zero or several layouts are skipped.

(defun layout-rename (prefix outfile / f dn names old new)
  (setq f (open outfile "w") dn (getvar "DWGNAME") names (adt-layouts))
  (setq new (substr dn 1 (- (strlen dn) 4)))
  (if (and (/= prefix "") (wcmatch (strcase new) (strcat (strcase prefix) "*")))
    (setq new (substr new (1+ (strlen prefix)))))
  (cond
    ((/= (length names) 1) (write-line (strcat "SKIP|" (itoa (length names)) " layouts") f))
    ((= (setq old (car names)) new) (write-line (strcat "SAME|" old) f))
    (T
      (command "_.-LAYOUT" "_R" old new)
      (if (member new (adt-layouts))
        (progn (command "_.QSAVE") (write-line (strcat "OK|" old "|" new) f))
        (write-line (strcat "FAIL|" old "|" new) f))))
  (close f)
  (princ))
