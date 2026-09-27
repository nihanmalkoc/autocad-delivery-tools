;; Shared helpers. Every script is inlined into the .scr file (see README: SECURELOAD).

(defun adt-split (s d / r i c)
  (setq r nil c "" i 1)
  (while (<= i (strlen s))
    (if (= (substr s i 1) d) (setq r (cons c r) c "") (setq c (strcat c (substr s i 1))))
    (setq i (1+ i)))
  (reverse (cons c r)))

(defun adt-fname (p / i)
  (setq i (strlen p))
  (while (and (> i 0) (not (member (substr p i 1) '("\\" "/")))) (setq i (1- i)))
  (substr p (1+ i)))

(defun adt-this () (strcase (strcat (getvar "DWGPREFIX") (getvar "DWGNAME"))))

;; Plan files are "<drawing path>|OP|arg|arg..." lines. Returns this drawing's ops without the path.
(defun adt-plan (planfile / f line p r cur)
  (setq cur (adt-this))
  (if (setq f (open planfile "r"))
    (progn
      (while (setq line (read-line f))
        (setq p (adt-split line "|"))
        (if (= (strcase (car p)) cur) (setq r (cons (cdr p) r))))
      (close f)))
  (reverse r))

(defun adt-isxref (nm / b) (and (setq b (tblsearch "BLOCK" nm)) (= 4 (logand 4 (cdr (assoc 70 b))))))

(defun adt-resolved (nm) (= 32 (logand 32 (cdr (assoc 70 (tblsearch "BLOCK" nm))))))

;; Xref block names that have at least one insert in this drawing (nested xrefs are excluded).
(defun adt-xrefs (/ d r)
  (setq d (tblnext "BLOCK" T))
  (while d
    (if (and (= 4 (logand 4 (cdr (assoc 70 d))))
             (ssget "_X" (list (cons 0 "INSERT") (cons 2 (cdr (assoc 2 d))))))
      (setq r (cons (cdr (assoc 2 d)) r)))
    (setq d (tblnext "BLOCK")))
  r)

(defun adt-xrefcount (/ d n)
  (setq d (tblnext "BLOCK" T) n 0)
  (while d
    (if (= 4 (logand 4 (cdr (assoc 70 d)))) (setq n (1+ n)))
    (setq d (tblnext "BLOCK")))
  n)

;; Inserts of every xref whose file name matches the wcmatch pattern.
(defun adt-xref-inserts (pat / d ss e r)
  (setq r (ssadd) d (tblnext "BLOCK" T))
  (while d
    (if (and (= 4 (logand 4 (cdr (assoc 70 d)))) (assoc 1 d)
             (wcmatch (strcase (adt-fname (cdr (assoc 1 d)))) pat))
      (if (setq ss (ssget "_X" (list (cons 0 "INSERT") (cons 2 (cdr (assoc 2 d))))))
        (progn (setq e 0) (repeat (sslength ss) (ssadd (ssname ss e) r) (setq e (1+ e))))))
    (setq d (tblnext "BLOCK")))
  r)

;; "DR" -> "*_DR_????.DWG";  "PLN,FAC" -> "*_PLN_????.DWG,*_FAC_????.DWG"
(defun adt-type-pattern (types / r)
  (foreach tp (adt-split types ",")
    (setq r (if r (strcat r ",*_" (strcase tp) "_????`.DWG") (strcat "*_" (strcase tp) "_????`.DWG"))))
  r)

;; Paper space layout names (layoutlist is not available in accoreconsole).
(defun adt-layouts (/ r)
  (foreach e (dictsearch (namedobjdict) "ACAD_LAYOUT")
    (if (and (= (car e) 3) (/= (strcase (cdr e)) "MODEL")) (setq r (cons (cdr e) r))))
  (reverse r))

;; Layout that holds the given block, or the first paper space layout.
(defun adt-sheet-layout (blk / ss l)
  (if (and blk (/= blk "") (setq ss (ssget "_X" (list (cons 0 "INSERT") (cons 2 blk)))))
    (setq l (cdr (assoc 410 (entget (ssname ss 0))))))
  (if (or (not l) (= (strcase l) "MODEL")) (setq l (car (adt-layouts))))
  l)
