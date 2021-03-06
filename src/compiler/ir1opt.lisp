;;;; This file implements the IR1 optimization phase of the compiler.
;;;; IR1 optimization is a grab-bag of optimizations that don't make
;;;; major changes to the block-level control flow and don't use flow
;;;; analysis. These optimizations can mostly be classified as
;;;; "meta-evaluation", but there is a sizable top-down component as
;;;; well.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!C")

;;;; interface for obtaining results of constant folding

;;; Return true for an LVAR whose sole use is a reference to a
;;; constant leaf.
(defun constant-lvar-p (thing)
  (declare (type (or lvar null) thing))
  (and (lvar-p thing)
       (let* ((type (lvar-type thing))
              (principal-lvar (principal-lvar thing))
              (principal-use (lvar-uses principal-lvar))
              leaf)
         (or (and (ref-p principal-use)
                  (constant-p (setf leaf (ref-leaf principal-use)))
                  ;; LEAF may be a CONSTANT behind a cast that will
                  ;; later turn out to be of the wrong type.
                  ;; And ir1-transforms suffer from this because
                  ;; they expect LVAR-VALUE to be of a restricted type.
                  (or (not (lvar-reoptimize principal-lvar))
                      (ctypep (constant-value leaf) type)))
             ;; check for EQL types and singleton numeric types
             (values (type-singleton-p type))))))

;;; Are all the uses constant?
(defun constant-lvar-uses-p (thing)
  (declare (type (or lvar null) thing))
  (and (lvar-p thing)
       (let* ((type (lvar-type thing))
              (principal-lvar (principal-lvar thing))
              (uses (lvar-uses principal-lvar))
              leaf)
         (when (consp uses)
           (loop for use in uses
                 always
                 (and (ref-p use)
                      (constant-p (setf leaf (ref-leaf use)))
                      ;; LEAF may be a CONSTANT behind a cast that will
                      ;; later turn out to be of the wrong type.
                      ;; And ir1-transforms suffer from this because
                      ;; they expect LVAR-VALUE to be of a restricted type.
                      (or (not (lvar-reoptimize principal-lvar))
                          (ctypep (constant-value leaf) type))))))))

;;; Return the constant value for an LVAR whose only use is a constant
;;; node.
(declaim (ftype (function (lvar) t) lvar-value))
(defun lvar-value (lvar)
  (let ((use  (principal-lvar-use lvar))
        (type (lvar-type lvar))
        leaf)
    (if (and (ref-p use)
             (constant-p (setf leaf (ref-leaf use))))
        (constant-value leaf)
        (multiple-value-bind (constantp value) (type-singleton-p type)
          (unless constantp
            (error "~S used on non-constant LVAR ~S" 'lvar-value lvar))
          value))))

(defun lvar-uses-values (lvar)
  (let ((uses (principal-lvar-use lvar)))
    (loop for use in uses
          for leaf = (ref-leaf use)
          collect (constant-value leaf))))

;;;; interface for obtaining results of type inference

;;; Our best guess for the type of this lvar's value. Note that this
;;; may be VALUES or FUNCTION type, which cannot be passed as an
;;; argument to the normal type operations. See LVAR-TYPE.
;;;
;;; The result value is cached in the LVAR-%DERIVED-TYPE slot. If the
;;; slot is true, just return that value, otherwise recompute and
;;; stash the value there.
(defmacro lvar-type-using (lvar accessor)
  `(let ((uses (lvar-uses ,lvar)))
     (cond ((null uses) *empty-type*)
           ((listp uses)
            (do ((res (,accessor (first uses))
                      (values-type-union (,accessor (first current))
                                         res))
                 (current (rest uses) (rest current)))
                ((or (null current) (eq res *wild-type*))
                 res)))
           (t
            (,accessor uses)))))

(defun %lvar-derived-type (lvar)
  (lvar-type-using lvar node-derived-type))

;;; Return the derived type for LVAR's first value. This is guaranteed
;;; not to be a VALUES or FUNCTION type.
(declaim (ftype (sfunction (lvar) ctype) lvar-type))
(defun lvar-type (lvar)
  (single-value-type (lvar-derived-type lvar)))

;;; LVAR-CONSERVATIVE-TYPE
;;;
;;; Certain types refer to the contents of an object, which can
;;; change without type derivation noticing: CONS types and ARRAY
;;; types suffer from this:
;;;
;;;  (let ((x (the (cons fixnum fixnum) (cons a b))))
;;;     (setf (car x) c)
;;;     (+ (car x) (cdr x)))
;;;
;;; Python doesn't realize that the SETF CAR can change the type of X -- so we
;;; cannot use LVAR-TYPE which gets the derived results. Worse, still, instead
;;; of (SETF CAR) we might have a call to a user-defined function FOO which
;;; does the same -- so there is no way to use the derived information in
;;; general.
;;;
;;; So, the conservative option is to use the derived type if the leaf has
;;; only a single ref -- in which case there cannot be a prior call that
;;; mutates it. Otherwise we use the declared type or punt to the most general
;;; type we know to be correct for sure.
(defun lvar-conservative-type (lvar)
  (let ((derived-type (lvar-type lvar))
        (t-type *universal-type*))
    ;; Recompute using NODE-CONSERVATIVE-TYPE instead of derived type if
    ;; necessary -- picking off some easy cases up front.
    (cond ((or (eq derived-type t-type)
               ;; Can't use CSUBTYPEP!
               (type= derived-type (specifier-type 'list))
               (type= derived-type (specifier-type 'null)))
           derived-type)
          ((and (cons-type-p derived-type)
                (eq t-type (cons-type-car-type derived-type))
                (eq t-type (cons-type-cdr-type derived-type)))
           derived-type)
          ((and (array-type-p derived-type)
                (or (not (array-type-complexp derived-type))
                    (let ((dimensions (array-type-dimensions derived-type)))
                      (or (eq '* dimensions)
                          (every (lambda (dim) (eq '* dim)) dimensions)))))
           derived-type)
          ((type-needs-conservation-p derived-type)
           (single-value-type (lvar-type-using lvar node-conservative-type)))
          (t
           derived-type))))

(defun node-conservative-type (node)
  (let* ((derived-values-type (node-derived-type node))
         (derived-type (single-value-type derived-values-type)))
    (if (ref-p node)
        (let ((leaf (ref-leaf node)))
          (if (and (basic-var-p leaf)
                   (cdr (leaf-refs leaf)))
              (coerce-to-values
               (if (eq :declared (leaf-where-from leaf))
                   (leaf-type leaf)
                   (conservative-type derived-type)))
              derived-values-type))
        derived-values-type)))

(defun conservative-type (type)
  (cond ((or (eq type *universal-type*)
             (eq type (specifier-type 'list))
             (eq type (specifier-type 'null)))
         type)
        ((cons-type-p type)
         (specifier-type 'cons))
        ((array-type-p type)
         (if (array-type-complexp type)
             (make-array-type
              ;; ADJUST-ARRAY may change dimensions, but rank stays same.
              (let ((old (array-type-dimensions type)))
                (if (eq '* old)
                    old
                    (mapcar (constantly '*) old)))
              ;; Complexity cannot change.
              :complexp (array-type-complexp type)
              ;; Element type cannot change.
              :element-type (array-type-element-type type)
              :specialized-element-type (array-type-specialized-element-type type))
             ;; Simple arrays cannot change at all.
             type))
        ((union-type-p type)
         ;; Conservative union type is an union of conservative types.
         (let ((res *empty-type*))
           (dolist (part (union-type-types type) res)
             (setf res (type-union res (conservative-type part))))))
        (t
         ;; Catch-all.
         ;;
         ;; If the type contains some CONS types, the conservative type contains all
         ;; of them.
         (when (types-equal-or-intersect type (specifier-type 'cons))
           (setf type (type-union type (specifier-type 'cons))))
         ;; Similarly for non-simple arrays -- it should be possible to preserve
         ;; more information here, but really...
         (let ((non-simple-arrays (specifier-type '(and array (not simple-array)))))
           (when (types-equal-or-intersect type non-simple-arrays)
             (setf type (type-union type non-simple-arrays))))
         type)))

(defun type-needs-conservation-p (type)
  (cond ((eq type *universal-type*)
         ;; Excluding T is necessary, because we do want type derivation to
         ;; be able to narrow it down in case someone (most like a macro-expansion...)
         ;; actually declares something as having type T.
         nil)
        ((or (cons-type-p type) (and (array-type-p type) (array-type-complexp type)))
         ;; Covered by the next case as well, but this is a quick test.
         t)
        ((types-equal-or-intersect type (specifier-type '(or cons (and array (not simple-array)))))
         t)))

;;; If LVAR is an argument of a function, return a type which the
;;; function checks LVAR for.
#!-sb-fluid (declaim (inline lvar-externally-checkable-type))
(defun lvar-externally-checkable-type (lvar)
  (or (lvar-%externally-checkable-type lvar)
      (%lvar-%externally-checkable-type lvar)))
(defun %lvar-%externally-checkable-type (lvar)
  (declare (type lvar lvar))
  (let ((dest (lvar-dest lvar)))
    (if (not (and dest (combination-p dest)))
        ;; TODO: MV-COMBINATION
        (setf (lvar-%externally-checkable-type lvar) *wild-type*)
        (let* ((fun (combination-fun dest))
               (args (combination-args dest))
               (fun-type (lvar-type fun)))
          (setf (lvar-%externally-checkable-type fun) *wild-type*)
          (if (or (not (call-full-like-p dest))
                  (not (fun-type-p fun-type))
                  ;; FUN-TYPE might be (AND FUNCTION (SATISFIES ...)).
                  (fun-type-wild-args fun-type))
              (dolist (arg args)
                (when arg
                  (setf (lvar-%externally-checkable-type arg)
                        *wild-type*)))
              (map-combination-args-and-types
               (lambda (arg type &rest args)
                 (declare (ignore args))
                 (setf (lvar-%externally-checkable-type arg)
                       (acond ((lvar-%externally-checkable-type arg)
                               (values-type-intersection
                                it (coerce-to-values type)))
                              (t (coerce-to-values type)))))
               dest)))))
  (or (lvar-%externally-checkable-type lvar) *wild-type*))

;;;; interface routines used by optimizers

;;; This function is called by optimizers to indicate that something
;;; interesting has happened to the value of LVAR. Optimizers must
;;; make sure that they don't call for reoptimization when nothing has
;;; happened, since optimization will fail to terminate.
;;;
;;; We clear any cached type for the lvar and set the reoptimize flags
;;; on everything in sight.
(defun reoptimize-lvar (lvar)
  (declare (type (or lvar null) lvar))
  (when lvar
    (setf (lvar-%derived-type lvar) nil)
    (let ((dest (lvar-dest lvar)))
      (when dest
        (setf (lvar-reoptimize lvar) t)
        (setf (node-reoptimize dest) t)
        (binding* (;; Since this may be called during IR1 conversion,
                   ;; PREV may be missing.
                   (prev (node-prev dest) :exit-if-null)
                   (block (ctran-block prev))
                   (component (block-component block)))
          (setf (block-reoptimize block) t)
          (reoptimize-component component :maybe))
        (loop for cast in (lvar-dependent-casts lvar)
              unless (node-deleted cast)
              do
              (setf (node-reoptimize cast) t)
              (setf (block-reoptimize (node-block cast)) t)
              (reoptimize-component (node-component cast) :maybe))))
    (do-uses (node lvar)
      (setf (block-type-check (node-block node)) t)))
  (values))

(defun reoptimize-lvar-uses (lvar)
  (declare (type lvar lvar))
  (do-uses (use lvar)
    (setf (node-reoptimize use) t)
    (setf (block-reoptimize (node-block use)) t)
    (reoptimize-component (node-component use) :maybe)))

;;; Annotate NODE to indicate that its result has been proven to be
;;; TYPEP to RTYPE. After IR1 conversion has happened, this is the
;;; only correct way to supply information discovered about a node's
;;; type. If you screw with the NODE-DERIVED-TYPE directly, then
;;; information may be lost and reoptimization may not happen.
;;;
;;; What we do is intersect RTYPE with NODE's DERIVED-TYPE. If the
;;; intersection is different from the old type, then we do a
;;; REOPTIMIZE-LVAR on the NODE-LVAR.
(defun derive-node-type (node rtype &key from-scratch)
  (declare (type valued-node node) (type ctype rtype))
  (let* ((initial-type (node-derived-type node))
         (node-type (if from-scratch
                        *wild-type*
                        initial-type)))
    (unless (eq initial-type rtype)
      (let ((int (values-type-intersection node-type rtype))
            (lvar (node-lvar node)))
        ;; Don't use type/=, it will return NIL on unknown types.
        ;; Instead of checking the second value just negate TYPE=
        (unless (type= initial-type int)
          (when (and *check-consistency*
                     (eq int *empty-type*)
                     (not (eq rtype *empty-type*)))
            (aver (not from-scratch))
            (let ((*compiler-error-context* node))
              (compiler-warn
               "New inferred type ~S conflicts with old type:~
                ~%  ~S~%*** possible internal error? Please report this."
               (type-specifier rtype) (type-specifier node-type))))
          (setf (node-derived-type node) int)
          ;; If the new type consists of only one object, replace the
          ;; node with a constant reference.
          (when (and (ref-p node)
                     (lambda-var-p (ref-leaf node)))
            (let ((type (single-value-type int)))
              (when (and (member-type-p type)
                         (eql 1 (member-type-size type)))
                (change-ref-leaf node (find-constant
                                       (first (member-type-members type)))))))
          (reoptimize-lvar lvar)))))
  (values))


(defun type-asserted-p (lvar type)
  (or (values-subtypep (lvar-derived-type lvar) type)
      ;; Just doing values-subtypep is not enough since it may be an
      ;; intersection of types. Need to see if there's a cast that
      ;; actually checks that particular type.
      (do-uses (node lvar t)
        (unless
            (typecase node
              (cast
               (values-subtypep (coerce-to-values (cast-asserted-type node)) type))
              (t
               (values-subtypep (node-derived-type node) type)))
          (return)))))

;;; This is similar to DERIVE-NODE-TYPE, but asserts that it is an
;;; error for LVAR's value not to be TYPEP to TYPE. We implement it
;;; splitting off DEST a new CAST node; old LVAR will deliver values
;;; to CAST. If we improve the assertion, we set TYPE-CHECK to
;;; guarantee that the new assertion will be checked.
(defun assert-lvar-type (lvar type policy &optional context)
  (declare (type lvar lvar) (type ctype type))
  (unless (type-asserted-p lvar type)
    (let ((internal-lvar (make-lvar))
          (dest (lvar-dest lvar)))
      (substitute-lvar internal-lvar lvar)
      (let ((cast (insert-cast-before dest lvar type policy
                                      context)))
        (use-lvar cast internal-lvar)
        t))))


;;;; IR1-OPTIMIZE

;;; Do one forward pass over COMPONENT, deleting unreachable blocks
;;; and doing IR1 optimizations. We can ignore all blocks that don't
;;; have the REOPTIMIZE flag set. If COMPONENT-REOPTIMIZE is true when
;;; we are done, then another iteration would be beneficial.
(defun ir1-optimize (component fastp)
  (declare (type component component))
  (setf (component-reoptimize component) nil)
  (loop with block = (block-next (component-head component))
        with tail = (component-tail component)
        for last-block = block
        until (eq block tail)
        do (cond
             ;; We delete blocks when there is either no predecessor or the
             ;; block is in a lambda that has been deleted. These blocks
             ;; would eventually be deleted by DFO recomputation, but doing
             ;; it here immediately makes the effect available to IR1
             ;; optimization.
             ((or (block-delete-p block)
                  (null (block-pred block)))
              (delete-block-lazily block)
              (setq block (clean-component component block)))
             ((eq (functional-kind (block-home-lambda block)) :deleted)
              ;; Preserve the BLOCK-SUCC invariant that almost every block has
              ;; one successor (and a block with DELETE-P set is an acceptable
              ;; exception).
              (mark-for-deletion block)
              (setq block (clean-component component block)))
             (t
              (loop
                 (let ((succ (block-succ block)))
                   (unless (singleton-p succ)
                     (return)))

                 (let ((last (block-last block)))
                   (typecase last
                     (cif
                      (flush-dest (if-test last))
                      (when (unlink-node last)
                        (return)))
                     (exit
                      (when (maybe-delete-exit last)
                        (return)))))

                 (unless (join-successor-if-possible block)
                   (return)))
              (remove-equivalent-blocks block)
              (when (and (not fastp) (block-reoptimize block) (block-component block))
                (aver (not (block-delete-p block)))
                (ir1-optimize-block block))

              (cond ((and (block-delete-p block) (block-component block))
                     (setq block (clean-component component block)))
                    ((and (block-flush-p block) (block-component block))
                     (flush-dead-code block)))))
        do (when (eq block last-block)
             (setq block (block-next block))))

  (values))

;;; Loop over the nodes in BLOCK, acting on (and clearing) REOPTIMIZE
;;; flags.
;;;
;;; Note that although they are cleared here, REOPTIMIZE flags might
;;; still be set upon return from this function, meaning that further
;;; optimization is wanted (as a consequence of optimizations we did).
(defun ir1-optimize-block (block)
  (declare (type cblock block))
  ;; We clear the node and block REOPTIMIZE flags before doing the
  ;; optimization, not after. This ensures that the node or block will
  ;; be reoptimized if necessary.
  (setf (block-reoptimize block) nil)
  (do-nodes (node nil block :restart-p t)
    (when (node-reoptimize node)
      ;; As above, we clear the node REOPTIMIZE flag before optimizing.
      (setf (node-reoptimize node) nil)
      (typecase node
        (ref)
        (combination
         ;; With a COMBINATION, we call PROPAGATE-FUN-CHANGE whenever
         ;; the function changes, and call IR1-OPTIMIZE-COMBINATION if
         ;; any argument changes.
         (ir1-optimize-combination node))
        (cif
         (ir1-optimize-if node))
        (creturn
         ;; KLUDGE: We leave the NODE-OPTIMIZE flag set going into
         ;; IR1-OPTIMIZE-RETURN, since IR1-OPTIMIZE-RETURN wants to
         ;; clear the flag itself. -- WHN 2002-02-02, quoting original
         ;; CMU CL comments
         (setf (node-reoptimize node) t)
         (ir1-optimize-return node))
        (mv-combination
         (ir1-optimize-mv-combination node))
        (exit
         ;; With an EXIT, we derive the node's type from the VALUE's
         ;; type.
         (let ((value (exit-value node)))
           (when value
             (derive-node-type node (lvar-derived-type value)))))
        (cset
         ;; PROPAGATE-FROM-SETS can do a better job if NODE-REOPTIMIZE
         ;; is accurate till the node actually has been reoptimized.
         (setf (node-reoptimize node) t)
         (ir1-optimize-set node))
        (cast
         (ir1-optimize-cast node)))))

  (values))

;;; Try to join with a successor block. If we succeed, we return true,
;;; otherwise false.
(defun join-successor-if-possible (block)
  (declare (type cblock block))
  (let ((next (first (block-succ block))))
    (when (block-start next)  ; NEXT is not an END-OF-COMPONENT marker
      (cond ( ;; We cannot combine with a successor block if:
             (or
              ;; the successor has more than one predecessor;
              (rest (block-pred next))
              ;; the successor is the current block (infinite loop);
              (eq next block)
              ;; the next block has a different cleanup, and thus
              ;; we may want to insert cleanup code between the
              ;; two blocks at some point;
              (not (eq (block-end-cleanup block)
                       (block-start-cleanup next)))
              ;; the next block has a different home lambda, and
              ;; thus the control transfer is a non-local exit.
              (not (eq (block-home-lambda block)
                       (block-home-lambda next)))
              ;; Stack analysis phase wants ENTRY to start a block...
              (entry-p (block-start-node next))
              (let ((last (block-last block)))
                (and (valued-node-p last)
                     (awhen (node-lvar last)
                       (or
                        ;; ... and a DX-allocator to end a block.
                        (lvar-dynamic-extent it)
                        ;; ... and for there to be no chance of there
                        ;; being two successive USEs of the same
                        ;; multi-valued LVAR in the same block (since
                        ;; we can only insert cleanup code at block
                        ;; boundaries, but need to discard
                        ;; multi-valued LVAR contents before they are
                        ;; overwritten).
                        (and (consp (lvar-uses it))
                             (not (lvar-single-value-p it))))))))
             nil)
            (t
             (join-blocks block next)
             t)))))

;;; Join together two blocks. The code in BLOCK2 is moved into BLOCK1
;;; and BLOCK2 is deleted from the DFO. We combine the optimize flags
;;; for the two blocks so that any indicated optimization gets done.
(defun join-blocks (block1 block2)
  (declare (type cblock block1 block2))
  (let* ((last1 (block-last block1))
         (last2 (block-last block2))
         (succ (block-succ block2))
         (start2 (block-start block2)))
    (do ((ctran start2 (node-next (ctran-next ctran))))
        ((not ctran))
      (setf (ctran-block ctran) block1))

    (unlink-blocks block1 block2)
    (dolist (block succ)
      (unlink-blocks block2 block)
      (link-blocks block1 block))

    (setf (ctran-kind start2) :inside-block)
    (setf (node-next last1) start2)
    (setf (ctran-use start2) last1)
    (setf (block-last block1) last2))

  (setf (block-flags block1)
        (attributes-union (block-flags block1)
                          (block-flags block2)))

  (let ((next (block-next block2))
        (prev (block-prev block2)))
    (setf (block-next prev) next)
    (setf (block-prev next) prev))

  (values))

;;; Delete any nodes in BLOCK whose value is unused and which have no
;;; side effects. We can delete sets of lexical variables when the set
;;; variable has no references.
(defun flush-dead-code (block)
  (declare (type cblock block))
  (setf (block-flush-p block) nil)
  (do-nodes-backwards (node lvar block :restart-p t)
    (if lvar
        (do-uses (other-node lvar)
          (when (and (neq node other-node)
                     (eq block (node-block other-node)))
            ;; This must be a preceding node and the current node will
            ;; overwrite the value, unlink the lvar and the node will
            ;; get a chance to be deleted on one of the next iterations
            (delete-lvar-use other-node)))
        (typecase node
          (ref
           (delete-ref node)
           (unlink-node node))
          (combination
           (when (and (not (node-tail-p node))
                      (flushable-combination-p node))
             (flush-combination node)))
          (mv-combination
           (when (eq (basic-combination-kind node) :local)
             (let ((fun (combination-lambda node)))
               (when (dolist (var (lambda-vars fun) t)
                       (when (or (leaf-refs var)
                                 (lambda-var-sets var))
                         (return nil)))
                 (mapc #'flush-dest (basic-combination-args node))
                 (delete-let fun)))))
          (exit
           (let ((value (exit-value node)))
             (when value
               (flush-dest value)
               (setf (exit-value node) nil))))
          (cset
           (let ((var (set-var node)))
             (when (and (lambda-var-p var)
                        (null (leaf-refs var)))
               (flush-dest (set-value node))
               (setf (basic-var-sets var)
                     (delq node (basic-var-sets var)))
               (unlink-node node))))
          (cast
           (unless (or (cast-type-check node)
                       (and (bound-cast-p node)
                            (bound-cast-check node)))
             (flush-dest (cast-value node))
             (unlink-node node)))))))

;;;; local call return type propagation

;;; This function is called on RETURN nodes that have their REOPTIMIZE
;;; flag set. It iterates over the uses of the RESULT, looking for
;;; interesting stuff to update the TAIL-SET. If a use isn't a local
;;; call, then we union its type together with the types of other such
;;; uses. We assign to the RETURN-RESULT-TYPE the intersection of this
;;; type with the RESULT's asserted type. We can make this
;;; intersection now (potentially before type checking) because this
;;; assertion on the result will eventually be checked (if
;;; appropriate.)
;;;
;;; We call MAYBE-CONVERT-TAIL-LOCAL-CALL on each local non-MV
;;; combination, which may change the successor of the call to be the
;;; called function, and if so, checks if the call can become an
;;; assignment. If we convert to an assignment, we abort, since the
;;; RETURN has been deleted.
(defun find-result-type (node)
  (declare (type creturn node))
  (let ((result (return-result node)))
    (collect ((use-union *empty-type* values-type-union))
      (do-uses (use result)
        (let ((use-home (node-home-lambda use)))
          (cond ((or (eq (functional-kind use-home) :deleted)
                     (block-delete-p (node-block use))))
                ((not (and (basic-combination-p use)
                           (eq (basic-combination-kind use) :local)))
                 (use-union (node-derived-type use)))
                ((or (eq (functional-kind (combination-lambda use)) :deleted)
                     (block-delete-p (lambda-block (combination-lambda use)))))
                (t
                 (aver (eq (lambda-tail-set use-home)
                           (lambda-tail-set (combination-lambda use))))
                 (when (combination-p use)
                   (when (nth-value 1 (maybe-convert-tail-local-call use))
                     (return-from find-result-type t)))))))
      (let ((int
             ;; (values-type-intersection
             ;; (continuation-asserted-type result) ; FIXME -- APD, 2002-01-26
             (use-union)
              ;; )
              ))
        (setf (return-result-type node) int))))
  nil)

;;; Do stuff to realize that something has changed about the value
;;; delivered to a return node. Since we consider the return values of
;;; all functions in the tail set to be equivalent, this amounts to
;;; bringing the entire tail set up to date. We iterate over the
;;; returns for all the functions in the tail set, reanalyzing them
;;; all (not treating NODE specially.)
;;;
;;; When we are done, we check whether the new type is different from
;;; the old TAIL-SET-TYPE. If so, we set the type and also reoptimize
;;; all the lvars for references to functions in the tail set. This
;;; will cause IR1-OPTIMIZE-COMBINATION to derive the new type as the
;;; results of the calls.
(defun ir1-optimize-return (node)
  (declare (type creturn node))
  (let ((lambda (return-lambda node)))
    (tagbody
     :restart
       (let* ((tails (lambda-tail-set lambda))
              (funs (tail-set-funs tails)))
         (collect ((res *empty-type* values-type-union))
           (dolist (fun funs)
             (let ((return (lambda-return fun)))
               (when return
                 (when (node-reoptimize return)
                   (setf (node-reoptimize return) nil)
                   (when (find-result-type return)
                     (go :restart)))
                 (res (return-result-type return)))))

           (when (type/= (res) (tail-set-type tails))
             (setf (tail-set-type tails) (res))
             (dolist (fun (tail-set-funs tails))
               (dolist (ref (leaf-refs fun))
                 (reoptimize-lvar (node-lvar ref)))))))))

  (values))

;;;; IF optimization

;;; Check whether the predicate is known to be true or false,
;;; deleting the IF node in favor of the appropriate branch when this
;;; is the case.
;;; Similarly, when both branches are equivalent, branch directly to either
;;; of them.
;;; Also, if the test has multiple uses, replicate the node when possible...
;;; in fact, splice in direct jumps to the right branch if possible.
(defun ir1-optimize-if (node)
  (declare (type cif node))
  (let ((test (if-test node))
        (block (node-block node)))
    (let* ((type (lvar-type test))
           (consequent  (if-consequent  node))
           (alternative (if-alternative node))
           (victim
             (cond ((constant-lvar-p test)
                    (if (lvar-value test) alternative consequent))
                   ((not (types-equal-or-intersect type (specifier-type 'null)))
                    alternative)
                   ((type= type (specifier-type 'null))
                    consequent)
                   ((or (eq consequent alternative)
                        (blocks-equivalent-p alternative consequent))
                    ;; Even if the references are the same they can have
                    ;; different derived types based on the TEST
                    ;; Don't lose the second type when killing it.
                    (let ((consequent-ref (block-start-node consequent)))
                      (derive-node-type consequent-ref
                                        (values-type-union
                                         (node-derived-type consequent-ref)
                                         (node-derived-type (block-start-node alternative)))
                                        :from-scratch t))
                    alternative))))
      (when victim
        (kill-if-branch-1 node test block victim)
        (return-from ir1-optimize-if (values))))
    (tension-if-if-1 node test block)
    (duplicate-if-if-1 node test block)
    (values)))

;; When we know that we only have a single successor, kill the victim
;; ... unless the victim and the remaining successor are the same.
(defun kill-if-branch-1 (node test block victim)
  (declare (type cif node))
  (flush-dest test)
  (when (rest (block-succ block))
    (unlink-blocks block victim))
  (setf (component-reanalyze (node-component node)) t)
  (unlink-node node))

;; When if/if conversion would leave (if ... (if nil ...)) or
;; (if ... (if not-nil ...)), splice the correct successor right
;; in.
(defun tension-if-if-1 (node test block)
  (when (and (eq (block-start-node block) node)
             (listp (lvar-uses test)))
    (do-uses (use test)
      (when (immediately-used-p test use)
        (let* ((type (single-value-type (node-derived-type use)))
               (target (if (type= type (specifier-type 'null))
                           (if-alternative node)
                           (multiple-value-bind (typep surep)
                               (ctypep nil type)
                             (and (not typep) surep
                                  (if-consequent node))))))
          (when target
            (let ((pred (node-block use)))
              (cond ((listp (lvar-uses test))
                     (change-block-successor pred block target)
                     (delete-lvar-use use))
                    (t
                     ;; only one use left. Just kill the now-useless
                     ;; branch to avoid spurious code deletion notes.
                     (aver (rest (block-succ block)))
                     (kill-if-branch-1
                      node test block
                      (if (eql target (if-alternative node))
                          (if-consequent node)
                          (if-alternative node)))
                     (return-from tension-if-if-1))))))))))

;; Finally, duplicate EQ-nil tests
(defun duplicate-if-if-1 (node test block)
  (when (and (eq (block-start-node block) node)
             (listp (lvar-uses test)))
    (do-uses (use test)
      (when (immediately-used-p test use)
        (convert-if-if use node)
        ;; leave the last use as is, instead of replacing
        ;; the (singly-referenced) CIF node with a duplicate.
        (when (not (listp (lvar-uses test))) (return))))))

;;; Create a new copy of an IF node that tests the value of the node
;;; USE. The test must have >1 use, and must be immediately used by
;;; USE. NODE must be the only node in its block (implying that
;;; block-start = if-test).
;;;
;;; This optimization has an effect semantically similar to the
;;; source-to-source transformation:
;;;    (IF (IF A B C) D E) ==>
;;;    (IF A (IF B D E) (IF C D E))
;;;
;;; We clobber the NODE-SOURCE-PATH of both the original and the new
;;; node so that dead code deletion notes will definitely not consider
;;; either node to be part of the original source. One node might
;;; become unreachable, resulting in a spurious note.
(defun convert-if-if (use node)
  (declare (type node use) (type cif node))
  (with-ir1-environment-from-node node
    (let* ((block (node-block node))
           (test (if-test node))
           (cblock (if-consequent node))
           (ablock (if-alternative node))
           (use-block (node-block use))
           (new-ctran (make-ctran))
           (new-lvar (make-lvar))
           (new-node (make-if :test new-lvar
                              :consequent cblock
                              :alternative ablock))
           (new-block (ctran-starts-block new-ctran)))
      (link-node-to-previous-ctran new-node new-ctran)
      (setf (lvar-dest new-lvar) new-node)
      (setf (block-last new-block) new-node)

      (unlink-blocks use-block block)
      (%delete-lvar-use use)
      (add-lvar-use use new-lvar)
      (link-blocks use-block new-block)

      (link-blocks new-block cblock)
      (link-blocks new-block ablock)

      (push "<IF Duplication>" (node-source-path node))
      (push "<IF Duplication>" (node-source-path new-node))

      (reoptimize-lvar test)
      (reoptimize-lvar new-lvar)
      (setf (component-reanalyze *current-component*) t)))
  (values))

;;;; exit IR1 optimization

;;; This function attempts to delete an exit node, returning true if
;;; it deletes the block as a consequence:
;;; -- If the exit is degenerate (has no ENTRY), then we don't do
;;;    anything, since there is nothing to be done.
;;; -- If the exit node and its ENTRY have the same home lambda then
;;;    we know the exit is local, and can delete the exit. We change
;;;    uses of the Exit-Value to be uses of the original lvar,
;;;    then unlink the node. If the exit is to a TR context, then we
;;;    must do MERGE-TAIL-SETS on any local calls which delivered
;;;    their value to this exit.
;;; -- If there is no value (as in a GO), then we skip the value
;;;    semantics.
;;;
;;; This function is also called by environment analysis, since it
;;; wants all exits to be optimized even if normal optimization was
;;; omitted.
(defun maybe-delete-exit (node)
  (declare (type exit node))
  (let ((value (exit-value node))
        (entry (exit-entry node)))
    (when (and entry
               (eq (node-home-lambda node) (node-home-lambda entry)))
      (setf (entry-exits entry) (delq node (entry-exits entry)))
      (if value
          (delete-filter node (node-lvar node) value)
          (unlink-node node)))))


;;;; combination IR1 optimization

;;; Report as we try each transform?
#!+sb-show
(defvar *show-transforms-p* nil)

(defun check-important-result (node info)
  (when (and (null (node-lvar node))
             (ir1-attributep (fun-info-attributes info) important-result)
             (neq (combination-info node) :important-result-discarded))
    (let ((*compiler-error-context* node))
      (setf (combination-info node) :important-result-discarded)
      (compiler-style-warn
       "The return value of ~A should not be discarded."
       (lvar-fun-name (basic-combination-fun node) t)))))

(defglobal *debug-auto-dx* nil)
;;; Generalized transform: For each downward funarg, unless it is
;;; a global var (like #'EQL), or the user already DXified,
;;; or this transform already ran, then try to wrap in DX-FLET.
;;; Change the call only if at least one DXable arg is known
;;; to be a fuction. If no eligible arg is, then do nothing.
;;; For now this only works on globally named functions.
(defun dxify-downward-funargs (node dxable-args fun-name)
  (when *debug-auto-dx*
    (format t "~&DXifying funargs to ~S~%" fun-name))
  (let* ((dx-flets)
         (received-args)
         (passed-args))
    ;; Experience shows that users place incorrect DYNAMIC-EXTENT declarations
    ;; without due consideration and care. Since the declaration was ignored
    ;; in more contexts than not, it was relatively harmless.
    ;; In light of that, only make this transform if willing to generate
    ;; wrong code, or if the declaration can be trusted.
    ;; [It's seems to be true that users who want this are OK with lack of
    ;; tail-callability and/or potential stack exhaustion due to the assumption
    ;; that callers should always use more stack space. You should really
    ;; only do that if you don't also need an arbitrarily long call chain.
    ;; MAP and friends are good examples where this pertains]
    (when #+sb-xc-host t ; always trust our own code
          #-sb-xc-host
          (or (package-locked-p ; callee "probably" won't get redefined
               (symbol-package (fun-name-block-name fun-name)))
              (policy node (= safety 0)))
      (dolist (arg-spec dxable-args)
        (when (symbolp arg-spec)
          ;; If there are keywords, we had better have a FUN-TYPE
          (let ((fun-type (lvar-type (combination-fun node))))
            ;; Can't do anything unless we can ascertain where
            ;; the keyword arguments start.
            (when (fun-type-p fun-type)
              (let* ((keys-index
                      (+ (length (fun-type-required fun-type))
                         (length (fun-type-optional fun-type))))
                     (keywords-supplied
                      (nthcdr keys-index (combination-args node))))
                ;; Everything in a keyword position needs to be
                ;; constant, or else no transform occurs.
                (loop
                   (unless (cdr keywords-supplied) (return))
                   (let ((keyword (car keywords-supplied)))
                     (unless (constant-lvar-p keyword)
                       (return))
                     (when (eq (lvar-value keyword) arg-spec)
                       ;; Map it to a positional arg
                       (setq arg-spec (1+ keys-index))
                       (return))
                     (setq keywords-supplied (cddr keywords-supplied))
                     (incf keys-index 2)))))))
        (when (integerp arg-spec)
          ;; OK, turn the Nth argument into a dx-flet
          (let* ((arg (or (nth arg-spec (combination-args node))
                          (return-from dxify-downward-funargs nil)))
                 (use (principal-lvar-use arg)))
            (when (and (ref-p use)
                       (lambda-p (ref-leaf use))
                       (neq (leaf-extent (lambda-parent (ref-leaf use)))
                            :always-dynamic))
              (unless received-args
                (setq received-args
                      (make-gensym-list (length (combination-args node))))
                (setq passed-args (copy-list received-args)))
              (let ((tempname (let ((*gensym-counter* (length dx-flets)))
                                (gensym "LAMBDA")))
                    (original-lambda
                     (functional-inline-expansion
                      (lambda-entry-fun (ref-leaf use)))))
                (aver (typep original-lambda '(cons (eql lambda))))
                (let ((original-lambda-list (second original-lambda)))
                  ;; KISS - the closure that you're passing can have 0 or more
                  ;; mandatory args and nothing else.
                  (unless (intersection original-lambda-list lambda-list-keywords)
                    (push `(,tempname ,original-lambda-list
                             (%funcall ,(nth arg-spec received-args)
                                       ,@original-lambda-list))
                          dx-flets)
                    (setf (nth arg-spec passed-args) `#',tempname)))))))))
    (when dx-flets
      (let ((new
             `(lambda ,received-args
                (dx-flet ,(nreverse dx-flets)
                  (,@(if (symbolp fun-name) `(,fun-name) `(funcall #',fun-name))
                   ,@passed-args)))))
        (when *debug-auto-dx*
          (format t "->~%~S~%" new))
        new))))

;;; This does not work. The intent was to prepend this transform to the list
;;; of (FUN-INFO-TRANSFORMS INFO) when applicable, in the known fun case.
;;; But the reason it doesn't work isn't that the transform doesn't transform
;;; the code - it does; but compiler doesn't appear to respect the DX-FLET.
(defglobal *dxify-args-transform*
  (make-transform :type (specifier-type 'function)
                  :function (lambda (node)
                              (or (let ((name (combination-fun-source-name node)))
                                    (dxify-downward-funargs
                                     node (fun-name-dx-args name) name))
                                  (give-up-ir1-transform)))
                  :note "auto-DX"))

;;; Do IR1 optimizations on a COMBINATION node.
(declaim (ftype (function (combination) (values)) ir1-optimize-combination))
(defun ir1-optimize-combination (node)
  (when (lvar-reoptimize (basic-combination-fun node))
    (propagate-fun-change node)
    (when (node-deleted node)
      (return-from ir1-optimize-combination))
    (maybe-terminate-block node nil))
  (let ((args (basic-combination-args node))
        (info (basic-combination-fun-info node))
        (kind (basic-combination-kind node)))
    (flet ((clear-reoptimize-args ()
             (dolist (arg args)
               (when arg
                 (setf (lvar-reoptimize arg) nil))))
           (process-info ()
             (check-important-result node info)
             (let ((fun (fun-info-derive-type info)))
               (when fun
                 (let ((res (funcall fun node)))
                   (when res
                     (derive-node-type node (coerce-to-values res))
                     (maybe-terminate-block node nil)))))))
      (ecase kind
        (:local
         (let ((fun (combination-lambda node)))
           (if (eq (functional-kind fun) :let)
               (propagate-let-args node fun)
               (propagate-local-call-args node fun))))
        (:error
         (clear-reoptimize-args))
        ((:full :unknown-keys)
         (clear-reoptimize-args)
         (cond (info
                ;; This is a known function marked NOTINLINE
                (process-info))
               (t
                ;; Check against the DEFINED-TYPE unless TYPE is already good.
                (let* ((fun (basic-combination-fun node))
                       (uses (lvar-uses fun))
                       (leaf (when (ref-p uses) (ref-leaf uses))))
                  (multiple-value-bind (type defined-type)
                      (cond ((global-var-p leaf)
                             (values (leaf-type leaf) (leaf-defined-type leaf)))
                            ((eq kind :unknown-keys)
                             (values (lvar-fun-type fun) nil))
                            (t
                             (values nil nil)))
                    (when (or (and (eq kind :unknown-keys)
                                   (fun-type-p type))
                              (and (fun-type-p defined-type)
                                   (not (fun-type-p type))))
                      (validate-call-type node type leaf)))
                  (binding* ((name (and leaf ;; don't want to transform CASTs
                                        (lvar-fun-name fun))
                                   :exit-if-null)
                             (dxable-args (fun-name-dx-args name) :exit-if-null))
                    (awhen (dxify-downward-funargs node dxable-args name)
                      (transform-call node it name)))))))
        (:known
         (aver info)
         (clear-reoptimize-args)
         (process-info)
         (unless (eq (combination-kind node) :error) ;; casued by derive-type
           (let ((attr (fun-info-attributes info)))
             (when (constant-fold-call-p node)
               (constant-fold-call node)
               (return-from ir1-optimize-combination))
             (when (and (ir1-attributep attr commutative)
                        (= (length args) 2)
                        (constant-lvar-p (first args))
                        (not (constant-lvar-p (second args))))
               (setf (basic-combination-args node) (nreverse args))))

           (let ((fun-source-name (combination-fun-source-name node))
                 (optimizer (fun-info-optimizer info)))
             (unless (and optimizer (funcall optimizer node))
               ;; First give the VM a peek at the call
               (multiple-value-bind (style transform)
                   (combination-implementation-style node)
                 (ecase style
                   (:direct
                    ;; The VM knows how to handle this.
                    )
                   (:transform
                    ;; The VM mostly knows how to handle this.  We need
                    ;; to massage the call slightly, though.
                    (transform-call node transform fun-source-name))
                   ((:default :maybe)
                    ;; Let transforms have a crack at it.
                    ;; We should always try with the dxify-args transform,
                    ;; but ironically it *does* *not* *work* for any function
                    ;; that has FUNCTION-DESIGNATOR in its arg signature
                    ;; (pretty much any CL: function). This is just sad.
                    ;; Are type checks getting in the way?
                    (dolist (x (fun-info-transforms info))
                      #!+sb-show
                      (when *show-transforms-p*
                        (let* ((lvar (basic-combination-fun node))
                               (fname (lvar-fun-name lvar t)))
                          (/show "trying transform" x (transform-function x) "for" fname)))
                      (unless (ir1-transform node x)
                        #!+sb-show
                        (when *show-transforms-p*
                          (/show "quitting because IR1-TRANSFORM result was NIL"))
                        (return)))))))))))))
  (values))

(defun xep-tail-combination-p (node)
  (and (combination-p node)
       (let* ((lvar (combination-lvar node))
              (dest (when (lvar-p lvar) (lvar-dest lvar)))
              (lambda (when (return-p dest) (return-lambda dest))))
         (and (lambda-p lambda)
              (eq :external (lambda-kind lambda))))))

;;; If NODE doesn't return (i.e. return type is NIL), then terminate
;;; the block there, and link it to the component tail.
;;;
;;; Except when called during IR1 convertion, we delete the
;;; continuation if it has no other uses. (If it does have other uses,
;;; we reoptimize.)
;;;
;;; Termination on the basis of a continuation type is
;;; inhibited when:
;;; -- The continuation is deleted (hence the assertion is spurious), or
;;; -- We are in IR1 conversion (where THE assertions are subject to
;;;    weakening.) FIXME: Now THE assertions are not weakened, but new
;;;    uses can(?) be added later. -- APD, 2003-07-17
;;;
;;; Why do we need to consider LVAR type? -- APD, 2003-07-30
(defun maybe-terminate-block (node ir1-converting-not-optimizing-p)
  (declare (type (or basic-combination cast cset ref) node))
  (let* ((block (node-block node))
         (lvar (node-lvar node))
         (ctran (node-next node))
         (tail (component-tail (block-component block)))
         (succ (first (block-succ block))))
    (declare (ignore lvar))
    (unless (or (and (eq node (block-last block)) (eq succ tail))
                (block-delete-p block))
      ;; Even if the combination will never return, don't terminate if this
      ;; is the tail call of a XEP: doing that would inhibit TCO.
      (when (and (eq (node-derived-type node) *empty-type*)
                 (not (xep-tail-combination-p node)))
        (cond (ir1-converting-not-optimizing-p
               (cond
                 ((block-last block)
                  (aver (eq (block-last block) node)))
                 (t
                  (setf (block-last block) node)
                  (setf (ctran-use ctran) nil)
                  (setf (ctran-kind ctran) :unused)
                  (setf (ctran-block ctran) nil)
                  (setf (node-next node) nil)
                  (link-blocks block (ctran-starts-block ctran)))))
              (t
               (node-ends-block node)))

        (let ((succ (first (block-succ block))))
          (unlink-blocks block succ)
          (setf (component-reanalyze (block-component block)) t)
          (aver (not (block-succ block)))
          (link-blocks block tail)
          (cond (ir1-converting-not-optimizing-p
                 (%delete-lvar-use node))
                (t (delete-lvar-use node)
                   (when (null (block-pred succ))
                     (mark-for-deletion succ)))))
        t))))

;;; This is called both by IR1 conversion and IR1 optimization when
;;; they have verified the type signature for the call, and are
;;; wondering if something should be done to special-case the call. If
;;; CALL is a call to a global function, then see whether it defined
;;; or known:
;;; -- If a DEFINED-FUN should be inline expanded, then convert
;;;    the expansion and change the call to call it. Expansion is
;;;    enabled if :INLINE or if SPACE=0. If the FUNCTIONAL slot is
;;;    true, we never expand, since this function has already been
;;;    converted. Local call analysis will duplicate the definition
;;;    if necessary. We claim that the parent form is LABELS for
;;;    context declarations, since we don't want it to be considered
;;;    a real global function.
;;; -- If it is a known function, mark it as such by setting the KIND.
;;;
;;; We return the leaf referenced (NIL if not a leaf) and the
;;; FUN-INFO assigned.
(defun recognize-known-call (call ir1-converting-not-optimizing-p
                             &optional unknown-keys)
  (declare (type combination call))
  (let* ((ref (lvar-uses (basic-combination-fun call)))
         (leaf (when (ref-p ref) (ref-leaf ref)))
         (inlinep (if (defined-fun-p leaf)
                      (defined-fun-inlinep leaf)
                      :no-chance)))
    (cond
      (unknown-keys
       (setf (basic-combination-kind call) :unknown-keys)
       (values leaf nil))
      ((eq inlinep :notinline)
       (let ((info (info :function :info (leaf-source-name leaf))))
         (when info
           (setf (basic-combination-fun-info call) info))
         (values nil nil)))
      ((not (and (global-var-p leaf)
                 (eq (global-var-kind leaf) :global-function)))
       (values leaf nil))
      ((and (ecase inlinep
              (:inline t)
              (:no-chance nil)
              ((nil :maybe-inline) (policy call (zerop space))))
            (defined-fun-p leaf)
            (defined-fun-inline-expansion leaf)
            (inline-expansion-ok call))
       ;; Inline: if the function has already been converted at another call
       ;; site in this component, we point this REF to the functional. If not,
       ;; we convert the expansion.
       ;;
       ;; For :INLINE case local call analysis will copy the expansion later,
       ;; but for :MAYBE-INLINE and NIL cases we only get one copy of the
       ;; expansion per component.
       ;;
       ;; FIXME: We also convert in :INLINE & FUNCTIONAL-KIND case below. What
       ;; is it for?
       (with-ir1-environment-from-node call
         (let ((fun (defined-fun-functional leaf)))
           (if (or (not fun)
                   (and (eq inlinep :inline) (functional-kind fun)))
               ;; Convert.
               (let* ((name (leaf-source-name leaf))
                      (res (ir1-convert-inline-expansion
                            name
                            (defined-fun-inline-expansion leaf)
                            leaf
                            inlinep
                            (info :function :info name))))
                 ;; Allow backward references to this function from following
                 ;; forms. (Reused only if policy matches.)
                 (push res (defined-fun-functionals leaf))
                 (change-ref-leaf ref res)
                 (unless ir1-converting-not-optimizing-p
                   (locall-analyze-component *current-component*)))
               ;; If we've already converted, change ref to the converted
               ;; functional.
               (change-ref-leaf ref fun))))
       (values (ref-leaf ref) nil))
      (t
       (let ((info (info :function :info (leaf-source-name leaf))))
         (if info
             (values leaf
                     (progn
                       (setf (basic-combination-kind call) :known)
                       (setf (basic-combination-fun-info call) info)))
             (values leaf nil)))))))

;;; Check whether CALL satisfies TYPE. If so, apply the type to the
;;; call, and do MAYBE-TERMINATE-BLOCK and return the values of
;;; RECOGNIZE-KNOWN-CALL. If an error, set the combination kind and
;;; return NIL, NIL. If the type is just FUNCTION, then skip the
;;; syntax check, arg/result type processing, but still call
;;; RECOGNIZE-KNOWN-CALL, since the call might be to a known lambda,
;;; and that checking is done by local call analysis.
(defun validate-call-type (call type fun &optional ir1-converting-not-optimizing-p)
  (declare (type combination call) (type ctype type))
  (let* ((where (when fun (leaf-where-from fun)))
         (same-file-p (eq :defined-here where)))
    (cond ((not (fun-type-p type))
           ;; Using the defined-type too early is a bit of a waste: during
           ;; conversion we cannot use the untrusted ASSERT-CALL-TYPE, etc.
           (when (and fun (not ir1-converting-not-optimizing-p))
             (let ((defined-type (leaf-defined-type fun)))
               (when (and (fun-type-p defined-type)
                          (neq fun (combination-type-validated-for-leaf call)))
                 ;; Don't validate multiple times against the same leaf --
                 ;; it doesn't add any information, but may generate the same warning
                 ;; multiple times.
                 (setf (combination-type-validated-for-leaf call) fun)
                 (when (and (valid-fun-use call defined-type
                                           :argument-test #'always-subtypep
                                           :result-test nil
                                           :lossage-fun (if same-file-p
                                                            #'compiler-warn
                                                            #'compiler-style-warn)
                                           :unwinnage-fun #'compiler-notify)
                            same-file-p)
                   (assert-call-type call defined-type nil)
                   (maybe-terminate-block call ir1-converting-not-optimizing-p)))))
           (recognize-known-call call ir1-converting-not-optimizing-p))
          (t
           (multiple-value-bind (valid unwinnage unknown-keys)
               (valid-fun-use call type
                              :argument-test #'always-subtypep
                              :result-test nil
                              :lossage-fun #'compiler-warn
                              :unwinnage-fun #'compiler-notify)
             (declare (ignore unwinnage))
             (cond (valid
                    (assert-call-type call type)
                    (maybe-terminate-block call ir1-converting-not-optimizing-p)
                    (setf (combination-kind call) :full)
                    (recognize-known-call call ir1-converting-not-optimizing-p unknown-keys))
                   (t
                    (setf (combination-kind call) :error)
                    (values nil nil))))))))

;;; This is called by IR1-OPTIMIZE when the function for a call has
;;; changed. If the call is local, we try to LET-convert it, and
;;; derive the result type. If it is a :FULL call, we validate it
;;; against the type, which recognizes known calls, does inline
;;; expansion, etc. If a call to a predicate in a non-conditional
;;; position or to a function with a source transform, then we
;;; reconvert the form to give IR1 another chance.
(defun propagate-fun-change (call)
  (declare (type combination call))
  (let ((*compiler-error-context* call)
        (fun-lvar (basic-combination-fun call)))
    (setf (lvar-reoptimize fun-lvar) nil)
    (case (combination-kind call)
      (:local
       (let ((fun (combination-lambda call)))
         (maybe-let-convert fun)
         (unless (member (functional-kind fun) '(:let :assignment :deleted))
           (derive-node-type call (tail-set-type (lambda-tail-set fun))))))
      (:full
       (multiple-value-bind (leaf info)
           (let* ((uses (lvar-uses fun-lvar))
                  (leaf (when (ref-p uses) (ref-leaf uses))))
             (validate-call-type call (lvar-fun-type fun-lvar) leaf))
         (cond ((functional-p leaf)
                (convert-call-if-possible
                 (lvar-uses (basic-combination-fun call))
                 call))
               ((not leaf))
               ((and (global-var-p leaf)
                     (eq (global-var-kind leaf) :global-function)
                     (leaf-has-source-name-p leaf)
                     (or (info :function :source-transform (leaf-source-name leaf))
                         (and info
                              (ir1-attributep (fun-info-attributes info)
                                              predicate)
                              (let ((lvar (node-lvar call)))
                                (and lvar (not (if-p (lvar-dest lvar))))))))
                (let ((name (leaf-source-name leaf))
                      (dummies (make-gensym-list
                                (length (combination-args call)))))
                  (transform-call call
                                  `(lambda ,dummies
                                     (,@(if (symbolp name)
                                            `(,name)
                                            `(funcall #',name))
                                        ,@dummies))
                                  (leaf-source-name leaf)
                                  nil))))))))
  (values))

;;;; known function optimization

;;; Add a failed optimization note to FAILED-OPTIMZATIONS for NODE,
;;; FUN and ARGS. If there is already a note for NODE and TRANSFORM,
;;; replace it, otherwise add a new one.
(defun record-optimization-failure (node transform args)
  (declare (type combination node) (type transform transform)
           (type (or fun-type list) args))
  (let* ((table (component-failed-optimizations *component-being-compiled*))
         (found (assoc transform (gethash node table))))
    (if found
        (setf (cdr found) args)
        (push (cons transform args) (gethash node table))))
  (values))

;;; Attempt to transform NODE using TRANSFORM-FUNCTION, subject to the
;;; call type constraint TRANSFORM-TYPE. If we are inhibited from
;;; doing the transform for some reason and FLAME is true, then we
;;; make a note of the message in FAILED-OPTIMIZATIONS for IR1
;;; finalize to pick up. We return true if the transform failed, and
;;; thus further transformation should be attempted. We return false
;;; if either the transform succeeded or was aborted.
(defun ir1-transform (node transform)
  (declare (type combination node) (type transform transform))
  (declare (notinline warn)) ; See COMPILER-WARN for rationale
  (let* ((type (transform-type transform))
         (fun (transform-function transform))
         (constrained (fun-type-p type))
         (table (component-failed-optimizations *component-being-compiled*))
         (flame (case (transform-important transform)
                  ((t) (policy node (>= speed inhibit-warnings)))
                  (:slightly (policy node (> speed inhibit-warnings)))))
         (*compiler-error-context* node)
         (policy-test (transform-policy transform)))
    (cond ((and policy-test
                (not (funcall policy-test node))))
          ((or (not constrained)
               (valid-fun-use node type))
           (multiple-value-bind (severity args)
               (catch 'give-up-ir1-transform
                 (transform-call node
                                 (funcall fun node)
                                 (combination-fun-source-name node))
                 (values :none nil))
             (ecase severity
               (:none
                (remhash node table)
                nil)
               (:aborted
                (setf (combination-kind node) :error)
                (when args
                  (apply #'warn args))
                (remhash node table)
                nil)
               (:failure
                (if args
                    (when flame
                      (record-optimization-failure node transform args))
                    (setf (gethash node table)
                          (remove transform (gethash node table) :key #'car)))
                t)
               (:delayed
                (remhash node table)
                nil))))
          ((and flame
                (valid-fun-use node
                               type
                               :argument-test #'types-equal-or-intersect
                               :result-test #'values-types-equal-or-intersect))
           (record-optimization-failure node transform type)
           t)
          (t
           t))))

;;; When we don't like an IR1 transform, we throw the severity/reason
;;; and args.
;;;
;;; GIVE-UP-IR1-TRANSFORM is used to throw out of an IR1 transform,
;;; aborting this attempt to transform the call, but admitting the
;;; possibility that this or some other transform will later succeed.
;;; If arguments are supplied, they are format arguments for an
;;; efficiency note.
;;;
;;; ABORT-IR1-TRANSFORM is used to throw out of an IR1 transform and
;;; force a normal call to the function at run time. No further
;;; optimizations will be attempted.
;;;
;;; DELAY-IR1-TRANSFORM is used to throw out of an IR1 transform, and
;;; delay the transform on the node until later. REASONS specifies
;;; when the transform will be later retried. The :OPTIMIZE reason
;;; causes the transform to be delayed until after the current IR1
;;; optimization pass. The :CONSTRAINT reason causes the transform to
;;; be delayed until after constraint propagation.
;;;
;;; FIXME: Now (0.6.11.44) that there are 4 variants of this (GIVE-UP,
;;; ABORT, DELAY/:OPTIMIZE, DELAY/:CONSTRAINT) and we're starting to
;;; do CASE operations on the various REASON values, it might be a
;;; good idea to go OO, representing the reasons by objects, using
;;; CLOS methods on the objects instead of CASE, and (possibly) using
;;; SIGNAL instead of THROW.
(declaim (ftype (function (&rest t) #+(and sb-xc-host ccl) *
                                    #-(and sb-xc-host ccl) nil) give-up-ir1-transform))
(defun give-up-ir1-transform (&rest args)
  (throw 'give-up-ir1-transform (values :failure args)))
(defun abort-ir1-transform (&rest args)
  (throw 'give-up-ir1-transform (values :aborted args)))
(defun delay-ir1-transform (node &rest reasons)
  (let ((assoc (assoc node *delayed-ir1-transforms*)))
    (cond ((not assoc)
            (setf *delayed-ir1-transforms*
                    (acons node reasons *delayed-ir1-transforms*))
            (throw 'give-up-ir1-transform :delayed))
          ((cdr assoc)
            (dolist (reason reasons)
              (pushnew reason (cdr assoc)))
            (throw 'give-up-ir1-transform :delayed)))))

;;; Poor man's catching and resignalling
;;; Implicit %GIVE-UP macrolet will resignal the give-up "condition"
(defmacro catch-give-up-ir1-transform ((form &optional args) &body gave-up-body)
  (let ((block (gensym "BLOCK"))
        (kind (gensym "KIND"))
        (args (or args (gensym "ARGS"))))
    `(block ,block
       (multiple-value-bind (,kind ,args)
           (catch 'give-up-ir1-transform
             (return-from ,block ,form))
         (ecase ,kind
           (:delayed
            (throw 'give-up-ir1-transform :delayed))
           ((:failure :aborted)
            (macrolet ((%give-up ()
                         `(throw 'give-up-ir1-transform (values ,',kind
                                                                ,',args))))
              ,@gave-up-body)))))))

;;; Clear any delayed transform with no reasons - these should have
;;; been tried in the last pass. Then remove the reason from the
;;; delayed transform reasons, and if any become empty then set
;;; reoptimize flags for the node. Return true if any transforms are
;;; to be retried.
(defun retry-delayed-ir1-transforms (reason)
  (setf *delayed-ir1-transforms*
        (remove-if-not #'cdr *delayed-ir1-transforms*))
  (let ((reoptimize nil))
    (dolist (assoc *delayed-ir1-transforms*)
      (let ((reasons (remove reason (cdr assoc))))
        (setf (cdr assoc) reasons)
        (unless reasons
          (let ((node (car assoc)))
            (unless (node-deleted node)
              (setf reoptimize t)
              (setf (node-reoptimize node) t)
              (let ((block (node-block node)))
                (setf (block-reoptimize block) t)
                (reoptimize-component (block-component block) :maybe)))))))
    reoptimize))

;;; Take the lambda-expression RES, IR1 convert it in the proper
;;; environment, and then install it as the function for the call
;;; NODE. We do local call analysis so that the new function is
;;; integrated into the control flow.
;;;
;;; We require the original function source name in order to generate
;;; a meaningful debug name for the lambda we set up. (It'd be
;;; possible to do this starting from debug names as well as source
;;; names, but as of sbcl-0.7.1.5, there was no need for this
;;; generality, since source names are always known to our callers.)
(defun transform-call (call res source-name &optional (reoptimize-combination t))
  (declare (type combination call) (list res))
  (aver (and (legal-fun-name-p source-name)
             (not (eql source-name '.anonymous.))))
  (node-ends-block call)
  (setf (combination-lexenv call)
        (make-lexenv :default (combination-lexenv call)
                     :policy
                     ;; The internal variables of a transform are not going to be
                     ;; interesting to the debugger, so there's no sense in
                     ;; suppressing the substitution of variables with only one use
                     ;; (the extra variables can slow down constraint propagation).
                     (augment-policy
                      preserve-single-use-debug-variables
                      0
                      (lexenv-policy
                       (combination-lexenv call)))))
  (with-ir1-environment-from-node call
    (with-component-last-block (*current-component*
                                (block-next (node-block call)))
      (let ((new-fun (ir1-convert-inline-lambda
                      res
                      :debug-name (debug-name 'lambda-inlined source-name)
                      :system-lambda t))
            (type (node-derived-type call))
            (ref (lvar-use (combination-fun call))))
        (change-ref-leaf ref new-fun)
        (setf (combination-kind call) :full)
        ;; Don't lose the original derived type
        (let ((return (lambda-return (main-entry new-fun))))
          (when return
            (do-uses (node (return-result
                            (lambda-return (main-entry new-fun))))
              (derive-node-type node type))))))
    ;; Must be done outside of WITH-COMPONENT-LAST-BLOCK
    ;; otherwise REMOVE-FROM-DFO might remove that block
    ;; but new code still will get attached to it.
    (locall-analyze-component *current-component*))
  (when reoptimize-combination
    ;; This is mainly to call PROPAGATE-LET-ARGS so that the
    ;; newly converted code gets to better types sooner.
    (setf (node-reoptimize call) nil)
    (ir1-optimize-combination call))
  (values))

(defun constant-fold-arg-p (name)
  (typecase name
    (null
     t)
    ((or symbol cons)
     (let* ((info (info :function :info name))
            (attributes (and info
                             (fun-info-attributes info))))
       (and info
            (ir1-attributep attributes foldable)
            (not (ir1-attributep attributes call)))))))

;;; Return T if the function is foldable and if it's marked as CALL
;;; all function arguments are FOLDABLE too.
(defun constant-fold-call-p (combination)
  (let* ((info (basic-combination-fun-info combination))
         (attr (fun-info-attributes info))
         (args (basic-combination-args combination)))
    (cond ((not (ir1-attributep attr foldable))
           nil)
          ((ir1-attributep attr call)
           (map-combination-args-and-types
            (lambda (arg type lvars &optional annotation)
              (declare (ignore type lvars))
              (unless (if (eql (car annotation) 'function-designator)
                          (let ((fun (or (lvar-fun-name arg t)
                                         (and (constant-lvar-p arg)
                                              (lvar-value arg)))))
                            (and fun
                                 (constant-fold-arg-p fun)))
                          (constant-lvar-p arg))
                (return-from constant-fold-call-p)))
            combination
            info
            (lambda ()
              (return-from constant-fold-call-p)))
           t)
          (t
           (every #'constant-lvar-p args)))))

;;; Replace a call to a foldable function of constant arguments with
;;; the result of evaluating the form. If there is an error during the
;;; evaluation, we give a warning and leave the call alone, making the
;;; call a :ERROR call.
;;;
;;; If there is more than one value, then we transform the call into a
;;; VALUES form.
(defun constant-fold-call (call)
  (let* ((fun-name (lvar-fun-name (combination-fun call) t))
         (type (info :function :type fun-name))
         (args (mapcar (lambda (lvar)
                         (if (lvar-p lvar)
                             (let ((name (lvar-fun-name lvar t)))
                               (if name
                                   (fdefinition name)
                                   (lvar-value lvar)))
                             lvar))
                       (let ((args (combination-args call)))
                         (if (fun-type-p type)
                             (resolve-key-args args type)
                             args)))))
    (multiple-value-bind (values win)
        (careful-call fun-name
                      args
                      call
                      ;; Note: CMU CL had COMPILER-WARN here, and that
                      ;; seems more natural, but it's probably not.
                      ;;
                      ;; It's especially not while bug 173 exists:
                      ;; Expressions like
                      ;;   (COND (END
                      ;;          (UNLESS (OR UNSAFE? (<= END SIZE)))
                      ;;            ...))
                      ;; can cause constant-folding TYPE-ERRORs (in
                      ;; #'<=) when END can be proved to be NIL, even
                      ;; though the code is perfectly legal and safe
                      ;; because a NIL value of END means that the
                      ;; #'<= will never be executed.
                      ;;
                      ;; Moreover, even without bug 173,
                      ;; quite-possibly-valid code like
                      ;;   (COND ((NONINLINED-PREDICATE END)
                      ;;          (UNLESS (<= END SIZE))
                      ;;            ...))
                      ;; (where NONINLINED-PREDICATE is something the
                      ;; compiler can't do at compile time, but which
                      ;; turns out to make the #'<= expression
                      ;; unreachable when END=NIL) could cause errors
                      ;; when the compiler tries to constant-fold (<=
                      ;; END SIZE).
                      ;;
                      ;; So, with or without bug 173, it'd be
                      ;; unnecessarily evil to do a full
                      ;; COMPILER-WARNING (and thus return FAILURE-P=T
                      ;; from COMPILE-FILE) for legal code, so we we
                      ;; use a wimpier COMPILE-STYLE-WARNING instead.
                      #-sb-xc-host #'compiler-style-warn
                      ;; On the other hand, for code we control, we
                      ;; should be able to work around any bug
                      ;; 173-related problems, and in particular we
                      ;; want to be alerted to calls to our own
                      ;; functions which aren't being folded away; a
                      ;; COMPILER-WARNING is butch enough to stop the
                      ;; SBCL build itself in its tracks.
                      #+sb-xc-host #'compiler-warn
                      "constant folding")
      (cond ((not win)
             (setf (combination-kind call) :error))
            ((and (proper-list-of-length-p values 1))
             (with-ir1-environment-from-node call
               (let* ((lvar (node-lvar call))
                      (prev (node-prev call))
                      (intermediate-ctran (make-ctran)))
                 (%delete-lvar-use call)
                 (setf (ctran-next prev) nil)
                 (setf (node-prev call) nil)
                 (reference-constant prev intermediate-ctran lvar
                                     (first values))
                 (link-node-to-previous-ctran call intermediate-ctran)
                 (reoptimize-lvar lvar)
                 (flush-combination call))))
            (t (let ((dummies (make-gensym-list (length args))))
                 (transform-call
                  call
                  `(lambda ,dummies
                     (declare (ignore ,@dummies))
                     (values ,@(mapcar (lambda (x) `',x) values)))
                  fun-name))))))
  (values))

;;;; local call optimization

;;; Propagate TYPE to LEAF and its REFS, marking things changed.
;;;
;;; If the leaf type is a function type, then just leave it alone, since TYPE
;;; is never going to be more specific than that (and TYPE-INTERSECTION would
;;; choke.)
;;;
;;; Also, if the type is one requiring special care don't touch it if the leaf
;;; has multiple references -- otherwise LVAR-CONSERVATIVE-TYPE is screwed.
(defun propagate-to-refs (leaf type)
  (declare (type leaf leaf) (type ctype type))
  (let ((var-type (leaf-type leaf))
        (refs (leaf-refs leaf)))
    (unless (or (fun-type-p var-type)
                (and (cdr refs)
                     (eq :declared (leaf-where-from leaf))
                     (type-needs-conservation-p var-type)))
      (let ((int (type-approx-intersection2 var-type type)))
        (when (type/= int var-type)
          (setf (leaf-type leaf) int)
          (let ((s-int (make-single-value-type int)))
            (dolist (ref refs)
              (derive-node-type ref s-int)
              (maybe-terminate-block ref nil)
              ;; KLUDGE: LET var substitution
              (let* ((lvar (node-lvar ref)))
                (when (and lvar (combination-p (lvar-dest lvar)))
                  (reoptimize-lvar lvar)))))))
      (values))))

;;; Iteration variable: exactly one SETQ of the form:
;;;
;;; (let ((var initial))
;;;   ...
;;;   (setq var (+ var step))
;;;   ...)
(defun maybe-infer-iteration-var-type (var initial-type)
  (binding* ((sets (lambda-var-sets var) :exit-if-null)
             (set (first sets))
             (() (null (rest sets)) :exit-if-null)
             (set-use (principal-lvar-use (set-value set)))
             (() (and (combination-p set-use)
                      (eq (combination-kind set-use) :known)
                      (fun-info-p (combination-fun-info set-use))
                      (not (node-to-be-deleted-p set-use))
                      (or (eq (combination-fun-source-name set-use) '+)
                          (eq (combination-fun-source-name set-use) '-)))
              :exit-if-null)
             (minusp (eq (combination-fun-source-name set-use) '-))
             (+-args (basic-combination-args set-use))
             (() (and (proper-list-of-length-p +-args 2 2)
                      (let ((first (principal-lvar-use
                                    (first +-args))))
                        (and (ref-p first)
                             (eq (ref-leaf first) var))))
              :exit-if-null)
             (step-type (lvar-type (second +-args)))
             (set-type (lvar-type (set-value set))))
    (when (and (numeric-type-p initial-type)
               (numeric-type-p step-type)
               (or (numeric-type-equal initial-type step-type)
                   ;; Detect cases like (LOOP FOR 1.0 to 5.0 ...), where
                   ;; the initial and the step are of different types,
                   ;; and the step is less contagious.
                   (numeric-type-equal initial-type
                                       (numeric-contagion initial-type
                                                          step-type))))
      (labels ((leftmost (x y cmp cmp=)
                 (cond ((eq x nil) nil)
                       ((eq y nil) nil)
                       ((listp x)
                        (let ((x1 (first x)))
                          (cond ((listp y)
                                 (let ((y1 (first y)))
                                   (if (funcall cmp x1 y1) x y)))
                                (t
                                 (if (funcall cmp x1 y) x y)))))
                       ((listp y)
                        (let ((y1 (first y)))
                          (if (funcall cmp= x y1) x y)))
                       (t (if (funcall cmp x y) x y))))
               (max* (x y) (leftmost x y #'> #'>=))
               (min* (x y) (leftmost x y #'< #'<=)))
        (multiple-value-bind (low high)
            (let ((step-type-non-negative (csubtypep step-type (specifier-type
                                                                '(real 0 *))))
                  (step-type-non-positive (csubtypep step-type (specifier-type
                                                                '(real * 0)))))
              (cond ((or (and step-type-non-negative (not minusp))
                         (and step-type-non-positive minusp))
                     (values (numeric-type-low initial-type)
                             (when (and (numeric-type-p set-type)
                                        (numeric-type-equal set-type initial-type))
                               (max* (numeric-type-high initial-type)
                                     (numeric-type-high set-type)))))
                    ((or (and step-type-non-positive (not minusp))
                         (and step-type-non-negative minusp))
                     (values (when (and (numeric-type-p set-type)
                                        (numeric-type-equal set-type initial-type))
                               (min* (numeric-type-low initial-type)
                                     (numeric-type-low set-type)))
                             (numeric-type-high initial-type)))
                    (t
                     (values nil nil))))
          (modified-numeric-type initial-type
                                 :low low
                                 :high high
                                 :enumerable nil))))))
(deftransform + ((x y) * * :result result)
  "check for iteration variable reoptimization"
  (let ((dest (principal-lvar-end result))
        (use (principal-lvar-use x)))
    (when (and (ref-p use)
               (set-p dest)
               (eq (ref-leaf use)
                   (set-var dest)))
      (reoptimize-lvar (set-value dest))))
  (give-up-ir1-transform))

;;; Figure out the type of a LET variable that has sets. We compute
;;; the union of the INITIAL-TYPE and the types of all the set
;;; values and to a PROPAGATE-TO-REFS with this type.
(defun propagate-from-sets (var initial-type)
  (let ((changes (not (csubtypep (lambda-var-last-initial-type var) initial-type)))
        (types nil))
    (dolist (set (lambda-var-sets var))
      (let ((type (lvar-type (set-value set))))
        (push type types)
        (when (node-reoptimize set)
          (let ((old-type (node-derived-type set)))
            (unless (values-subtypep old-type type)
              (derive-node-type set (make-single-value-type type))
              (maybe-terminate-block set nil)
              (setf changes t)))
          (setf (node-reoptimize set) nil))))
    (when changes
      (setf (lambda-var-last-initial-type var) initial-type)
      (let ((res-type (or (maybe-infer-iteration-var-type var initial-type)
                          (apply #'type-union initial-type types))))
        (propagate-to-refs var res-type))))
  (values))

;;; If a LET variable, find the initial value's type and do
;;; PROPAGATE-FROM-SETS. We also derive the VALUE's type as the node's
;;; type.
(defun ir1-optimize-set (node)
  (declare (type cset node))
  (let ((var (set-var node)))
    (when (and (lambda-var-p var) (leaf-refs var))
      (let ((home (lambda-var-home var)))
        (when (eq (functional-kind home) :let)
          (let* ((initial-value (let-var-initial-value var))
                 (initial-type (lvar-type initial-value)))
            (setf (lvar-reoptimize initial-value) nil)
            (propagate-from-sets var initial-type))))))
  (derive-node-type node (make-single-value-type
                          (lvar-type (set-value node))))
  (setf (node-reoptimize node) nil)
  (values))

;;; Return true if the value of REF will always be the same (and is
;;; thus legal to substitute.)
(defun constant-reference-p (ref)
  (declare (type ref ref))
  (let ((leaf (ref-leaf ref)))
    (typecase leaf
      ((or constant functional) t)
      (lambda-var
       (null (lambda-var-sets leaf)))
      (defined-fun
       (not (eq (defined-fun-inlinep leaf) :notinline)))
      (global-var
       (case (global-var-kind leaf)
         (:global-function
          (let ((name (leaf-source-name leaf)))
            (or #-sb-xc-host
                (eq (symbol-package (fun-name-block-name name))
                    *cl-package*)
                (info :function :info name)))))))))

;;; If we have a non-set LET var with a single use, then (if possible)
;;; replace the variable reference's LVAR with the arg lvar.
;;;
;;; We change the REF to be a reference to NIL with unused value, and
;;; let it be flushed as dead code. A side effect of this substitution
;;; is to delete the variable.
(defun substitute-single-use-lvar (arg var)
  (declare (type lvar arg) (type lambda-var var))
  (binding* ((ref (first (leaf-refs var)))
             (lvar (node-lvar ref) :exit-if-null)
             (dest (lvar-dest lvar))
             (dest-lvar (when (valued-node-p dest) (node-lvar dest))))
    (when (and
           ;; Think about (LET ((A ...)) (IF ... A ...)): two
           ;; LVAR-USEs should not be met on one path. Another problem
           ;; is with dynamic-extent.
           (eq (lvar-uses lvar) ref)
           (not (block-delete-p (node-block ref)))
           ;; If the destinatation is dynamic extent, don't substitute unless
           ;; the source is as well.
           (or (not dest-lvar)
               (not (lvar-dynamic-extent dest-lvar))
               (lvar-dynamic-extent lvar))
           (typecase dest
             ;; we should not change lifetime of unknown values lvars
             (cast
              (and (type-single-value-p (lvar-derived-type arg))
                   (multiple-value-bind (pdest pprev)
                       (principal-lvar-end lvar)
                     (declare (ignore pdest))
                     (lvar-single-value-p pprev))
                   ;; CASTs can disappear, don't substitute if
                   ;; DEST-LVAR has other uses (this will be
                   ;; insufficient if we have a CAST-CAST chain, but
                   ;; works well for a single CAST)
                   (or (null dest-lvar)
                       (atom (lvar-uses dest-lvar)))))
             (mv-combination
              (or (eq (basic-combination-fun dest) lvar)
                  (and (eq (basic-combination-kind dest) :local)
                       (type-single-value-p (lvar-derived-type arg)))))
             ((or creturn exit)
              ;; While CRETURN and EXIT nodes may be known-values,
              ;; they have their own complications, such as
              ;; substitution into CRETURN may create new tail calls.
              nil)
             (t
              (aver (lvar-single-value-p lvar))
              t))
           (eq (node-home-lambda ref)
               (lambda-home (lambda-var-home var))))
      (let ((ref-type (single-value-type (node-derived-type ref))))
        (cond ((csubtypep (single-value-type (lvar-type arg)) ref-type)
               (substitute-lvar-uses lvar arg
                                     ;; Really it is (EQ (LVAR-USES LVAR) REF):
                                     t)
               (delete-lvar-use ref))
              (t
               (let* ((value (make-lvar))
                      (cast (insert-cast-before ref value ref-type
                                                ;; KLUDGE: it should be (TYPE-CHECK 0)
                                                *policy*)))
                 (setf (cast-type-to-check cast) *wild-type*)
                 (substitute-lvar-uses value arg
                                       ;; FIXME
                                       t)
                 (%delete-lvar-use ref)
                 (add-lvar-use cast lvar)))))
      (setf (node-derived-type ref) *wild-type*)
      (change-ref-leaf ref (find-constant nil))
      (delete-ref ref)
      (unlink-node ref)
      (reoptimize-lvar lvar)
      t)))

;;; Delete a LET, removing the call and bind nodes, and warning about
;;; any unreferenced variables. Note that FLUSH-DEAD-CODE will come
;;; along right away and delete the REF and then the lambda, since we
;;; flush the FUN lvar.
(defun delete-let (clambda)
  (declare (type clambda clambda))
  (aver (functional-letlike-p clambda))
  (note-unreferenced-fun-vars clambda)
  (let ((call (let-combination clambda)))
    (flush-dest (basic-combination-fun call))
    (unlink-node call)
    (unlink-node (lambda-bind clambda))
    (setf (lambda-bind clambda) nil))
  (setf (functional-kind clambda) :zombie)
  (let ((home (lambda-home clambda)))
    (setf (lambda-lets home) (delete clambda (lambda-lets home))))
  (values))

;;; This function is called when one of the arguments to a LET
;;; changes. We look at each changed argument. If the corresponding
;;; variable is set, then we call PROPAGATE-FROM-SETS. Otherwise, we
;;; consider substituting for the variable, and also propagate
;;; derived-type information for the arg to all the VAR's refs.
;;;
;;; Substitution is inhibited when the arg leaf's derived type isn't a
;;; subtype of the argument's leaf type. This prevents type checking
;;; from being defeated, and also ensures that the best representation
;;; for the variable can be used.
;;;
;;; Substitution of individual references is inhibited if the
;;; reference is in a different component from the home. This can only
;;; happen with closures over top level lambda vars. In such cases,
;;; the references may have already been compiled, and thus can't be
;;; retroactively modified.
;;;
;;; If all of the variables are deleted (have no references) when we
;;; are done, then we delete the LET.
;;;
;;; Note that we are responsible for clearing the LVAR-REOPTIMIZE
;;; flags.
(defun propagate-let-args (call fun)
  (declare (type basic-combination call) (type clambda fun))
  (map-combination-arg-var
   (lambda (arg var type)
     (cond
       ((lambda-var-deleted var))
       ((lambda-var-sets var)
        (propagate-from-sets var type))
       ((and arg
             (let ((use (lvar-uses arg)))
               (when (ref-p use)
                 (let ((leaf (ref-leaf use)))
                   (when (and (constant-reference-p use)
                              (csubtypep (leaf-type leaf)
                                         ;; (NODE-DERIVED-TYPE USE) would
                                         ;; be better -- APD, 2003-05-15
                                         (leaf-type var)))
                     (propagate-to-refs var type)
                     (unless (preserve-single-use-debug-var-p call var)
                       (update-lvar-dependencies leaf arg)
                       (propagate-ref-dx use arg var)
                       (let ((use-component (node-component use)))
                         (substitute-leaf-if
                          (lambda (ref)
                            (cond ((eq (node-component ref) use-component)
                                   t)
                                  (t
                                   (aver (lambda-toplevelish-p (lambda-home fun)))
                                   nil)))
                          leaf var)))
                     t))))))
       ((and arg
             (null (rest (leaf-refs var)))
             (not (preserve-single-use-debug-var-p call var))
             (substitute-single-use-lvar arg var)))
       (t
        (propagate-to-refs var type))))
   call
   :reoptimize t)

  (when (every #'not (basic-combination-args call))
    (delete-let fun))

  (values))

;;; This function is called when one of the args to a non-LET local
;;; call changes. For each changed argument corresponding to an unset
;;; variable, we compute the union of the types across all calls and
;;; propagate this type information to the var's refs.
;;;
;;; If the function has an entry-fun, then we don't do anything: since
;;; it has a XEP we would not discover anything.
;;;
;;; If the function is an optional-entry-point, we will just make sure
;;; &REST lists are known to be lists. Doing the regular rigamarole
;;; can erronously propagate too strict types into refs: see
;;; BUG-655203-REGRESSION in tests/compiler.pure.lisp.
;;;
;;; We can clear the LVAR-REOPTIMIZE flags for arguments in all calls
;;; corresponding to changed arguments in CALL, since the only use in
;;; IR1 optimization of the REOPTIMIZE flag for local call args is
;;; right here.
(defun propagate-local-call-args (call fun)
  (declare (type combination call) (type clambda fun))
  (unless (functional-entry-fun fun)
    (if (lambda-optional-dispatch fun)
        ;; We can still make sure &REST is known to be a list.
        (loop for var in (lambda-vars fun)
              do (let ((info (lambda-var-arg-info var)))
                   (when (and info (eq :rest (arg-info-kind info)))
                     (propagate-from-sets var (specifier-type 'list)))))
        ;; The normal case.
        (let* ((vars (lambda-vars fun))
               (union (mapcar (lambda (arg var)
                                (when (and arg
                                           (lvar-reoptimize arg)
                                           (null (basic-var-sets var)))
                                  (lvar-type arg)))
                              (basic-combination-args call)
                              vars))
               (this-ref (lvar-use (basic-combination-fun call))))

          (dolist (arg (basic-combination-args call))
            (when arg
              (setf (lvar-reoptimize arg) nil)))

          (dolist (ref (leaf-refs fun))
            (let ((dest (node-dest ref)))
              (unless (or (eq ref this-ref) (not dest))
                (setq union
                      (mapcar (lambda (this-arg old)
                                (when old
                                  (setf (lvar-reoptimize this-arg) nil)
                                  (type-union (lvar-type this-arg) old)))
                              (basic-combination-args dest)
                              union)))))

          (loop for var in vars
                and type in union
                when type do (propagate-to-refs var type)))))

  (values))

;;;; multiple values optimization

;;; Do stuff to notice a change to a MV combination node. There are
;;; two main branches here:
;;;  -- If the call is local, then it is already a MV let, or should
;;;     become one. Note that although all :LOCAL MV calls must eventually
;;;     be converted to :MV-LETs, there can be a window when the call
;;;     is local, but has not been LET converted yet. This is because
;;;     the entry-point lambdas may have stray references (in other
;;;     entry points) that have not been deleted yet.
;;;  -- The call is full. This case is somewhat similar to the non-MV
;;;     combination optimization: we propagate return type information and
;;;     notice non-returning calls. We also have an optimization
;;;     which tries to convert MV-CALLs into MV-binds.
(defun ir1-optimize-mv-combination (node)
  (let ((fun (basic-combination-fun node)))
    (unless (and (node-p (lvar-uses fun))
                 (node-to-be-deleted-p (lvar-uses fun)))
      (ecase (basic-combination-kind node)
        (:local
         (let ((lambda (combination-lambda node)))
           (when (lvar-reoptimize fun)
             (setf (lvar-reoptimize fun) nil)
             (maybe-let-convert lambda))
           (cond ((neq (functional-kind lambda) :mv-let)
                  (loop for arg in (basic-combination-args node)
                        do
                        (setf (lvar-reoptimize arg) nil)))
                 ((convert-mv-bind-to-let node))
                 (t
                  (propagate-let-args node lambda)))))
        (:full
         (let* ((fun-changed (lvar-reoptimize fun)))
           (loop for arg in (basic-combination-args node)
                 do
                 (setf (lvar-reoptimize arg) nil))
           (when fun-changed
             (setf (lvar-reoptimize fun) nil)
             (let ((type (lvar-fun-type fun t)))
               (when (fun-type-p type)
                 (derive-node-type node (fun-type-returns type))))
             (maybe-terminate-block node nil)
             (let ((use (lvar-uses fun)))
               (when (and (ref-p use) (functional-p (ref-leaf use)))
                 (convert-call-if-possible use node)
                 (when (eq (basic-combination-kind node) :local)
                   (maybe-let-convert (ref-leaf use))))))
           (unless (or (eq (basic-combination-kind node) :local)
                       (eq (lvar-fun-name fun) '%throw))
             (ir1-optimize-mv-call node))))
        (:error))))

  (values))

(defun count-values (call &optional min)
  (loop for arg in (basic-combination-args call)
        for nvals = (nth-value 1 (values-types (lvar-derived-type arg)))
        if (eq nvals :unknown)
        do (unless min
             (return))
        else
        sum nvals))

(defun check-mv-call-arguments (call)
  (let ((*compiler-error-context* call)
        (max-accepted (nth-value 1 (fun-type-nargs
                                    (lvar-fun-type
                                     (basic-combination-fun call)))))
        (min-args (count-values call t)))
    (cond ((not min-args))
          ((and max-accepted (> min-args max-accepted))
           (compiler-warn
            "MULTIPLE-VALUE-CALL with at least ~R values when the function expects ~
              at most ~R."
            min-args max-accepted)
           (setf (basic-combination-kind call) :error)
           nil)
          (t))))

(defun ir1-optimize-mv-call (node)
  (let* ((fun (basic-combination-fun node))
         (uses (lvar-uses (basic-combination-fun node)))
         (count (count-values node)))
    (if count
        (with-ir1-environment-from-node node
          (let* ((dums (make-gensym-list count))
                 (ignore (gensym))
                 (ref-p (ref-p uses))
                 (new-fun (ir1-convert-lambda
                           `(lambda (&optional ,@dums &rest ,ignore)
                              (declare (ignore ,ignore))
                              ;; REFERENCE-LEAF does a better job referencing
                              ;; DEFINED-FUNs than just using the LVAR.
                              ,(cond (ref-p
                                      `(%funcall ,(ref-leaf uses) ,@dums))
                                     (t
                                      `(%funcall-lvar ,fun ,@dums)))))))
            (cond (ref-p
                   (change-ref-leaf uses new-fun))
                  (t
                   (reoptimize-lvar fun)
                   (setf (basic-combination-fun node)
                         (insert-ref-before new-fun node))))
            (aver (eq (basic-combination-kind node) :full))
            (locall-analyze-component *current-component*)
            (aver (eq (basic-combination-kind node) :local))))
        ;; The total argument count is not known, but all the known
        ;; values can already cause a conflict.
        (check-mv-call-arguments node)))
  (values))

;;; If we see:
;;;    (multiple-value-bind
;;;     (x y)
;;;     (values xx yy)
;;;      ...)
;;; Convert to:
;;;    (let ((x xx)
;;;       (y yy))
;;;      ...)
;;;
;;; What we actually do is convert the VALUES combination into a
;;; normal LET combination calling the original :MV-LET lambda. If
;;; there are extra args to VALUES, discard the corresponding
;;; lvars. If there are insufficient args, insert references to NIL.
(defun convert-mv-bind-to-let (call)
  (declare (type mv-combination call))
  (let* ((args (basic-combination-args call))
         (use (lvar-uses (first args))))
    (when (and (singleton-p args)
               (combination-p use)
               (eq (lvar-fun-name (combination-fun use))
                   'values))
      (setf (lvar-reoptimize (car args)) nil)
      (let* ((fun (combination-lambda call))
             (vars (lambda-vars fun))
             (vals (combination-args use))
             (nvars (length vars))
             (nvals (length vals)))
        (cond ((> nvals nvars)
               (mapc #'flush-dest (subseq vals nvars))
               (setq vals (subseq vals 0 nvars)))
              ((< nvals nvars)
               (with-ir1-environment-from-node use
                 (let ((node-prev (node-prev use)))
                   (setf (node-prev use) nil)
                   (setf (ctran-next node-prev) nil)
                   (collect ((res vals))
                     (loop for count below (- nvars nvals)
                           for prev = node-prev then ctran
                           for ctran = (make-ctran)
                           and lvar = (make-lvar use)
                           do (reference-constant prev ctran lvar nil)
                              (res lvar)
                           finally (link-node-to-previous-ctran
                                    use ctran))
                     (setq vals (res)))))))
        (setf (combination-args use) vals)
        (flush-dest (combination-fun use))
        (let ((fun-lvar (basic-combination-fun call)))
          (setf (lvar-dest fun-lvar) use)
          (setf (combination-fun use) fun-lvar)
          (flush-lvar-externally-checkable-type fun-lvar))
        (setf (combination-kind use) :local)
        (setf (functional-kind fun) :let)
        (flush-dest (first (basic-combination-args call)))
        (unlink-node call)
        (when vals
          (reoptimize-lvar (first vals)))
        ;; Propagate derived types from the VALUES call to its args:
        ;; transforms can leave the VALUES call with a better type
        ;; than its args have, so make sure not to throw that away.
        (let ((types (values-type-types (node-derived-type use))))
          (dolist (val vals)
            (when types
              (let ((type (pop types)))
                (assert-lvar-type val type **zero-typecheck-policy**)))))
        ;; Propagate declared types of MV-BIND variables.
        (propagate-to-args use fun)
        (reoptimize-call use))
      t)))

;;; If we see:
;;;    (values-list (list x y z))
;;;
;;; Convert to:
;;;    (values x y z)
;;;
;;; In implementation, this is somewhat similar to
;;; CONVERT-MV-BIND-TO-LET. We grab the args of LIST and make them
;;; args of the VALUES-LIST call, flushing the old argument lvar
;;; (allowing the LIST to be flushed.)
;;;
;;; FIXME: Thus we lose possible type assertions on (LIST ...).
(defoptimizer (values-list optimizer) ((list) node)
  (let ((use (lvar-uses list)))
    (when (and (combination-p use)
               (eq (lvar-fun-name (combination-fun use))
                   'list))

      ;; FIXME: VALUES might not satisfy an assertion on NODE-LVAR.
      (change-ref-leaf (lvar-uses (combination-fun node))
                       (find-free-fun 'values "in a strange place"))
      (setf (combination-kind node) :full)
      (let ((args (combination-args use)))
        (dolist (arg args)
          (setf (lvar-dest arg) node)
          (flush-lvar-externally-checkable-type arg))
        (setf (combination-args use) nil)
        (flush-dest list)
        (flush-combination use)
        (setf (combination-args node) args))
      t)))

;;; If VALUES appears in a non-MV context, then effectively convert it
;;; to a PROG1. This allows the computation of the additional values
;;; to become dead code.
(deftransform values ((&rest vals) * * :node node)
  (unless (lvar-single-value-p (node-lvar node))
    (give-up-ir1-transform))
  (setf (node-derived-type node)
        (make-short-values-type (list (single-value-type
                                       (node-derived-type node)))))
  (principal-lvar-single-valuify (node-lvar node))
  (if vals
      (let ((dummies (make-gensym-list (length (cdr vals)))))
        `(lambda (val ,@dummies)
           (declare (ignore ,@dummies))
           val))
      nil))

;;; TODO:
;;; - CAST chains;
(defun delete-cast (cast)
  (declare (type cast cast))
  (let ((value (cast-value cast))
        (lvar (cast-lvar cast)))
    (when (and (bound-cast-p cast)
               (bound-cast-check cast))
      (flush-combination (bound-cast-check cast))
      (setf (bound-cast-check cast) nil))
    (delete-filter cast lvar value)
    (when lvar
      (reoptimize-lvar lvar)
      (when (lvar-single-value-p lvar)
        (note-single-valuified-lvar lvar)))
    (values)))

(defun compile-time-type-error-context (context)
  #+sb-xc-host context
  #-sb-xc-host (source-to-string context))

(defun may-delete-function-designator-cast (cast)
  ;; If the destination is a combination-fun that means the function
  ;; is called here and not passed somewhere else, there's no longer a
  ;; need to check the function type, the arguments to the call will
  ;; do the same job.
  (let* ((lvar (cast-lvar cast))
         (dest (and lvar
                    (lvar-dest lvar))))
    (and (basic-combination-p dest)
         (eq (basic-combination-fun dest) lvar))))

(defun may-delete-bound-cast (cast)
  (when (bound-cast-check cast)
    (when (constant-lvar-p (bound-cast-bound cast))
      (setf (cast-asserted-type cast)
            (specifier-type `(integer 0 (,(lvar-value (bound-cast-bound cast)))))
            (bound-cast-derived cast) t))
    (when (policy cast (= insert-array-bounds-checks 0))
      (flush-combination (bound-cast-check cast))
      (setf (bound-cast-check cast) nil)))
  (bound-cast-derived cast))

(defun may-delete-modifying-cast (cast)
  (or (not (modifying-cast-caller cast)) ;; already warned
      (let* ((value (cast-value cast))
             (uses (lvar-uses value))
             (lvar (or (and (ref-p uses)
                            (lambda-var-ref-lvar uses))
                       value))
             (*compiler-error-context* cast))
        (flet ((modifiable-p (value)
                 (or (consp value)
                     (and (arrayp value)
                          (not (typep value '(vector * 0))))
                     (hash-table-p value))))
          (cond ((constant-lvar-p lvar)
                 (let ((value (lvar-value lvar)))
                   (when (modifiable-p value)
                     (warn 'constant-modified
                           :fun-name (shiftf (modifying-cast-caller cast) nil) ;; warn once
                           :values (list value))
                     t)))
                ((constant-lvar-uses-p lvar)
                 (let ((values (lvar-uses-values lvar)))
                   (when (and values
                              (every #'modifiable-p values))
                     (warn 'constant-modified
                           :fun-name (shiftf (modifying-cast-caller cast) nil) ;; warn once
                           :values values)
                     t))))))))

(defun may-delete-cast-with-hook (cast)
  (or (not (cast-with-hook-hook cast)) ;; run once
      (let ((value (cast-value cast)))
        (when (constant-lvar-p value)
          (let ((*compiler-error-context* cast))
            (funcall (cast-with-hook-hook cast)
                     (lvar-value value))
            ;; Run once
            (setf (cast-with-hook-hook cast) nil))
          t))))

(defun may-delete-cast (cast)
  (typecase cast
    (vestigial-exit-cast
     nil)
    (function-designator-cast
     (may-delete-function-designator-cast cast))
    (bound-cast
     (may-delete-bound-cast cast))
    (modifying-cast
     (may-delete-modifying-cast cast))
    (cast-with-hook
     (may-delete-cast-with-hook cast))
    (t t)))

;;; Delete or move around casts when possible
(defun maybe-delete-cast (cast)
  (let ((lvar (cast-lvar cast))
        (value (cast-value cast)))
    (cond ((not (may-delete-cast cast))
           nil)
          ((or
            ;; If it's a call (decided by may-delete-cast), it'll do
            ;; all the aproriate checking
            (function-designator-cast-p cast)
            (values-subtypep (lvar-derived-type value)
                             (cast-asserted-type cast)))
           (delete-cast cast)
           t)
          ((and (listp (lvar-uses value))
                lvar)
           ;; Turn (the vector (if x y #()) into
           ;; (if x (the vector y) #())
           (let ((atype (cast-asserted-type cast))
                 (ctran (node-next cast))
                 (dest (lvar-dest lvar))
                 next-block)
             (collect ((merges))
               (do-uses (use value)
                 (when (and (values-subtypep (node-derived-type use) atype)
                            (immediately-used-p value use))
                   (unless next-block
                     (when ctran (ensure-block-start ctran))
                     (setq next-block (first (block-succ (node-block cast))))
                     (ensure-block-start (node-prev cast))
                     (reoptimize-lvar lvar)
                     (setf (lvar-%derived-type value) nil))
                   (%delete-lvar-use use)
                   (add-lvar-use use lvar)
                   (unlink-blocks (node-block use) (node-block cast))
                   (link-blocks (node-block use) next-block)
                   (when (and (return-p dest)
                              (basic-combination-p use)
                              (eq (basic-combination-kind use) :local))
                     (merges use))))
               (dolist (use (merges))
                 (merge-tail-sets use))))))))

(defun ir1-optimize-cast (cast)
  (declare (type cast cast))
  (unless (maybe-delete-cast cast)
    (let* ((value (cast-value cast))
           (atype (cast-asserted-type cast))
           (value-type (lvar-derived-type value))
           (int (values-type-intersection value-type atype)))
      (derive-node-type cast int)
      (cond ((or (neq int *empty-type*)
                 (eq value-type *empty-type*)))
            ;; No need to transform into an analog of
            ;; %COMPILE-TIME-TYPE-ERROR, %CHECK-BOUND will signal at
            ;; run-time and %CHECK-BOUND ir2-converter will signal at
            ;; compile-time if it survives further stages of ir1
            ;; optimization.
            ((and (bound-cast-p cast)
                  (bound-cast-check cast)))
            (t
             (let ((context (node-source-form cast))
                   (detail (lvar-all-sources (cast-value cast))))
               (unless (cast-silent-conflict cast)
                 (filter-lvar
                  value
                  (if (cast-single-value-p cast)
                      `(list 'dummy)
                      `(multiple-value-call #'list 'dummy))))
               (filter-lvar
                (cast-value cast)
                ;; FIXME: Derived type.
                (if (cast-silent-conflict cast)
                    (let ((dummy-sym (gensym)))
                      `(let ((,dummy-sym 'dummy))
                         ,(internal-type-error-call dummy-sym atype
                                                    (cast-context cast))
                         ,dummy-sym))
                    `(%compile-time-type-error 'dummy
                                               ',(type-specifier atype)
                                               ',(type-specifier value-type)
                                               ',detail
                                               ',(compile-time-type-error-context context)
                                               ',(cast-context cast)))))
             ;; KLUDGE: FILTER-LVAR does not work for non-returning
             ;; functions, so we declare the return type of
             ;; %COMPILE-TIME-TYPE-ERROR to be * and derive the real type
             ;; here.
             (setq value (cast-value cast))
             (derive-node-type (lvar-uses value) *empty-type*)
             (maybe-terminate-block (lvar-uses value) nil)
             ;; FIXME: Is it necessary?
             (aver (null (block-pred (node-block cast))))
             (delete-block-lazily (node-block cast))
             (return-from ir1-optimize-cast)))
      (when (eq (node-derived-type cast) *empty-type*)
        (maybe-terminate-block cast nil))

      (when (and (cast-%type-check cast)
                 (values-subtypep value-type
                                  (cast-type-to-check cast)))
        (setf (cast-%type-check cast) nil))
      (setf (node-reoptimize cast) nil))))

(defun cast-type-check (cast)
  (declare (type cast cast))
  (let ((check (cast-%type-check cast)))
    (if (and check
             (cast-reoptimize cast)
             (values-subtypep (lvar-derived-type (cast-value cast))
                              (cast-type-to-check cast)))
        (setf (cast-%type-check cast) nil)
        check)))
