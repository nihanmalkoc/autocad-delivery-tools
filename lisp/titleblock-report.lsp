;; BLOCK|layout for every insert of the title block, followed by ATT|tag|FIELD or TEXT|value lines
;; (value last: it may contain "|").

(defun titleblock-report (blk outfile / f ss i e a ad)
  (setq f (open outfile "w"))
  (if (setq ss (ssget "_X" (list (cons 0 "INSERT") (cons 2 blk))))
    (progn
      (setq i 0)
      (repeat (sslength ss)
        (setq e (ssname ss i) i (1+ i))
        (write-line (strcat "BLOCK|" (cdr (assoc 410 (entget e)))) f)
        (setq a (entnext e))
        (while (and a (= "ATTRIB" (cdr (assoc 0 (setq ad (entget a))))))
          (write-line (strcat "ATT|" (cdr (assoc 2 ad)) "|" (if (assoc 360 ad) "FIELD" "TEXT") "|" (cdr (assoc 1 ad))) f)
          (setq a (entnext a)))))
    (write-line "NOBLOCK" f))
  (close f)
  (princ))
