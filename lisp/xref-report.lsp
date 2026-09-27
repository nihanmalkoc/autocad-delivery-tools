;; One line per xref insert: name|flags|saved path|INS|point|xscale,yscale|rotation|layer|layout
;; Xrefs without a top-level insert (nested) are reported as name|flags|path|NOINSERT.

(defun adt-pt (p) (strcat (rtos (car p) 2 4) "," (rtos (cadr p) 2 4) "," (rtos (caddr p) 2 4)))

(defun xref-report (outfile / f d fl nm ss e i)
  (setq f (open outfile "w") d (tblnext "BLOCK" T))
  (while d
    (setq fl (cdr (assoc 70 d)) nm (cdr (assoc 2 d)))
    (if (= 4 (logand 4 fl))
      (if (setq ss (ssget "_X" (list (cons 0 "INSERT") (cons 2 nm))))
        (progn
          (setq i 0)
          (repeat (sslength ss)
            (setq e (entget (ssname ss i)) i (1+ i))
            (write-line (strcat nm "|" (itoa fl) "|" (if (assoc 1 d) (cdr (assoc 1 d)) "")
                                "|INS|" (adt-pt (cdr (assoc 10 e)))
                                "|" (rtos (cdr (assoc 41 e)) 2 4) "," (rtos (cdr (assoc 42 e)) 2 4)
                                "|" (rtos (cdr (assoc 50 e)) 2 6)
                                "|" (cdr (assoc 8 e))
                                "|" (if (assoc 410 e) (cdr (assoc 410 e)) "")) f)))
        (write-line (strcat nm "|" (itoa fl) "|" (if (assoc 1 d) (cdr (assoc 1 d)) "") "|NOINSERT") f)))
    (setq d (tblnext "BLOCK")))
  (close f)
  (princ))
