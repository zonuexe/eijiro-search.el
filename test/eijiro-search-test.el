;;; eijiro-search-test.el --- Tests for eijiro-search  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path (expand-file-name "." default-directory))
(add-to-list 'load-path (expand-file-name "test" default-directory))
(require 'vui-stub)
(load-file (expand-file-name "eijiro-search.el" default-directory))

(defconst eijiro-search-test--fixture-file
  (expand-file-name "test/fixtures/sample-eijiro.txt" default-directory))

(ert-deftest eijiro-search-test-regex-pattern-rg-headword-tail ()
  (should
   (equal
    (eijiro-search--regex-pattern-for-rg "lisp$" nil)
    "lisp(?:$|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)")))

(ert-deftest eijiro-search-test-regex-pattern-rg-include-description-tail ()
  (should
   (equal
    (eijiro-search--regex-pattern-for-rg "発音$" t)
    "発音(?:$|◆|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)")))

(ert-deftest eijiro-search-test-regex-pattern-rg-head-anchor ()
  (should (equal (eijiro-search--regex-pattern-for-rg "^Lisp" nil)
                 "^■Lisp")))

(ert-deftest eijiro-search-test-regex-pattern-headword-tail ()
  (should
   (equal
    (eijiro-search--regex-pattern-for-headword "lisp$")
    "lisp\\(?:$\\|[[:space:]]*[{][^}]+[}][[:space:]]*$\\)")))

(ert-deftest eijiro-search-test-redirect-target-extraction ()
  (let* ((entry (list :meaning "<→a>◆＝<→b>◆〈英〉→c◆→d◆【参考】e ; f；g"))
         (targets (eijiro-search--redirect-targets entry)))
    (should (equal (delete-dups (copy-sequence targets))
                   '("a" "b" "c" "d" "e" "f" "g")))))

(ert-deftest eijiro-search-test-reference-target-excludes-japanese-only ()
  (let* ((entry (list :meaning "【参考】日本語 ; 日本語A ; foo's bar-bar ; preteen ; A-1"))
         (targets (eijiro-search--redirect-targets entry)))
    (should (equal targets '("foo's bar-bar" "preteen" "A-1")))))

(ert-deftest eijiro-search-test-reference-target-strips-japanese-paren-note ()
  (let* ((entry (list :meaning "【参考】Greek alphabet（ギリシャ文字） ; 日本語"))
         (targets (eijiro-search--redirect-targets entry)))
    (should (equal targets '("Greek alphabet")))))

(ert-deftest eijiro-search-test-split-for-rows-markers ()
  (should
   (equal (eijiro-search--split-for-rows "first◆second■third■・bullet")
          '("first" "second" "■third" "・bullet"))))

(ert-deftest eijiro-search-test-rank-prefers-plain-over-metadata ()
  (let* ((entries (list (list :term "lisp  {名-1}" :line-number 2)
                        (list :term "lisp" :line-number 1)))
         (sorted (eijiro-search--sort-entries entries "lisp" nil)))
    (should (equal (mapcar (lambda (e) (plist-get e :term)) sorted)
                   '("lisp" "lisp  {名-1}")))))

(ert-deftest eijiro-search-test-resolve-redirect-map-one-hop ()
  (skip-unless (executable-find "rg"))
  (let ((eijiro-search-dictionary-file eijiro-search-test--fixture-file))
    (let* ((entries (list (list :term "redirect-a" :meaning "<→redirect-b>")))
           (map (eijiro-search--resolve-redirect-map entries nil))
           (resolved (gethash "redirect-b" map)))
      (should resolved)
      (should (equal (plist-get resolved :term) "redirect-b")))))

(ert-deftest eijiro-search-test-search-regex-end-on-description-split ()
  (skip-unless (executable-find "rg"))
  (let ((eijiro-search-dictionary-file eijiro-search-test--fixture-file)
        (eijiro-search-max-results 50))
    (let ((entries (eijiro-search--search "発音$" "regex" t nil)))
      (should (cl-some (lambda (e)
                         (string= (plist-get e :term) "lisp  {名-2}"))
                       entries)))))

(ert-deftest eijiro-search-test-result-rows-insert-redirect-once-globally ()
  (let* ((entries (list (list :line-number 1 :term "a" :meaning "【参考】foo")
                        (list :line-number 2 :term "b" :meaning "【参考】foo")))
         (resolved (list :line-number 99 :term "foo" :meaning "resolved"))
         (redirect-map (make-hash-table :test 'equal))
         (rows nil)
         (heads nil))
    (puthash "foo" resolved redirect-map)
    (setq rows (eijiro-search--result-rows entries redirect-map nil))
    (setq heads (mapcar #'car rows))
    (should (= (cl-count "foo" heads :test #'string=) 1))))

(ert-deftest eijiro-search-test-fuzzy-initials-extraction ()
  (should (equal (eijiro-search--fuzzy-initials
                  "What You See Is What You Get"
                  nil)
                 "wysiwyg")))

(ert-deftest eijiro-search-test-fuzzy-acronym-word-pattern ()
  (should
   (equal
    (eijiro-search--fuzzy-acronym-word-pattern "wysiwyg")
    "w[[:alnum:]'_-]*[[:space:]]+y[[:alnum:]'_-]*[[:space:]]+s[[:alnum:]'_-]*[[:space:]]+i[[:alnum:]'_-]*[[:space:]]+w[[:alnum:]'_-]*[[:space:]]+y[[:alnum:]'_-]*[[:space:]]+g[[:alnum:]'_-]*")))

(ert-deftest eijiro-search-test-fuzzy-score-acronym-bonus ()
  (let ((expanded (eijiro-search--fuzzy-score
                   "wysiwyg"
                   "What You See Is What You Get"
                   nil))
        (plain (eijiro-search--fuzzy-score
                "wysiwyg"
                "wavy style in weird yellow grass"
                nil)))
    (should (numberp expanded))
    (should (numberp plain))
    (should (> expanded plain))))

(ert-deftest eijiro-search-test-fuzzy-search-finds-acronym-expansion-headword ()
  (skip-unless (executable-find "rg"))
  (let ((eijiro-search-dictionary-file eijiro-search-test--fixture-file)
        (eijiro-search-max-results 50))
    (let ((entries (eijiro-search--search "wysiwyg" "fuzzy" nil nil)))
      (should (cl-some (lambda (e)
                         (string= (plist-get e :term)
                                  "what you see is what you get"))
                       entries)))))

;;; eijiro-search-test.el ends here
