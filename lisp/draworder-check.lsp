;; Checks in the model space sort table that every TOP xref insert is drawn above all REF inserts.
;; Writes OK, WRONG, NOTOP or NOREF.

(defun adt-hex (h / r i c)
  (setq r 0.0 i 1 h (strcase h))
  (while (<= i (strlen h))
    (setq c (ascii (substr h i 1)) r (+ (* r 16.0) (if (>= c 65) (- c 55) (- c 48))) i (1+ i)))
  r)

(defun adt-sortkeys (/ ss br xd st lst e)
  (if (setq ss (ssget "_X" (list (cons 410 "Model"))))
    (progn
      (setq br (cdr (assoc 330 (entget (ssname ss 0)))))
      (if (and (setq xd (cdr (assoc 360 (entget br)))) (setq st (dictsearch xd "ACAD_SORTENTS")))
        (foreach g st
          (cond ((= (car g) 331) (setq e (cdr g)))
                ((and (= (car g) 5) e) (setq lst (cons (cons e (cdr g)) lst) e nil)))))))
  lst)

(defun adt-key (en tbl / a) (if (setq a (assoc en tbl)) (adt-hex (cdr a)) (adt-hex (cdr (assoc 5 (entget en))))))

(defun adt-ss-keys (ss tbl / i r)
  (setq i 0)
  (repeat (sslength ss) (setq r (cons (adt-key (ssname ss i) tbl) r) i (1+ i)))
  r)

(defun draworder-check (top refs outfile / f tbl tk rk)
  (setq f (open outfile "w") tbl (adt-sortkeys))
  (setq tk (adt-ss-keys (adt-xref-inserts (adt-type-pattern top)) tbl)
        rk (adt-ss-keys (adt-xref-inserts (adt-type-pattern refs)) tbl))
  (write-line (cond ((not tk) "NOTOP") ((not rk) "NOREF") ((> (apply 'min tk) (apply 'max rk)) "OK") (T "WRONG")) f)
  (close f)
  (princ))
