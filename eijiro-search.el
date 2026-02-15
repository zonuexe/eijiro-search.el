;;; eijiro-search.el --- Interactive dictionary search interface  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  USAMI Kenta

;; Author: USAMI Kenta <tadsan@zonu.me>
;; Created: 15 Feb 2026
;; Keywords: data
;; Homepage: https://github.com/zonuexe/eijiro-search.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (vui "1.0.0"))
;; License: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Interactive EIJIRO dictionary search UI with vui.
;;
;; Usage:
;;   M-x eijiro-search
;;
;; Customize `eijiro-search-dictionary-file' if your dictionary file is
;; located elsewhere.

;;; Code:

(require 'subr-x)
(require 'vui)
(eval-when-compile
  (require 'cl-lib))

(defgroup eijiro-search nil
  "Interactive dictionary search interface for EIJIRO text files."
  :group 'applications)

(defcustom eijiro-search-dictionary-file
  (expand-file-name "EIJIRO144-10.TXT"
                    (if load-file-name
                        (file-name-directory load-file-name)
                      default-directory))
  "Path to EIJIRO text dictionary file."
  :type 'file)

(defcustom eijiro-search-max-results 200
  "Maximum number of hits to display."
  :type 'integer)

(defcustom eijiro-search-headword-max-width 45
  "Maximum display width for the Headword column."
  :type 'integer)

(defvar eijiro-search--buffer-name "*EIJIRO Search*"
  "Buffer name for EIJIRO search UI.")

(defun eijiro-search--ensure-dictionary ()
  "Validate dictionary file settings."
  (unless (and (stringp eijiro-search-dictionary-file)
               (file-readable-p eijiro-search-dictionary-file))
    (user-error "Dictionary file is not readable: %s"
                eijiro-search-dictionary-file)))

(defconst eijiro-search--mode-options
  '(("text" . "Text")
    ("fuzzy" . "Fuzzy")
    ("regex" . "Regex"))
  "Search mode options for `vui-select'.")

(defun eijiro-search--fuzzy-needle (query)
  "Return fuzzy needle by removing whitespace from QUERY."
  (replace-regexp-in-string "[[:space:]]+" "" (or query "")))

(defun eijiro-search--fuzzy-pattern (query)
  "Return fuzzy regex for QUERY using subsequence-like matching."
  (let* ((needle (eijiro-search--fuzzy-needle query))
         (chars (string-to-list needle)))
    (if (null chars)
        ".*"
      (mapconcat (lambda (char)
                   (regexp-quote (string char)))
                 chars
                 ".*"))))

(defun eijiro-search--regex-pattern-for-rg (query &optional include-description)
  "Rewrite regex QUERY for rg over EIJIRO line format.
When INCLUDE-DESCRIPTION is non-nil, `$' can also match before `◆'."
  (let ((q (or query "")))
    (when (string-prefix-p "^" q)
      (setq q (concat "^■" (substring q 1))))
    (when (string-suffix-p "$" q)
      (setq q (concat (substring q 0 -1)
                      (if include-description
                          "(?:$|◆|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)"
                        "(?:$|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)"))))
    q))

(defun eijiro-search--regex-pattern-for-headword (query)
  "Rewrite regex QUERY for parsed headword string."
  (let ((q (or query "")))
    (when (string-suffix-p "$" q)
      (setq q (concat (substring q 0 -1)
                      "\\(?:$\\|[[:space:]]*[{][^}]+[}][[:space:]]*$\\)")))
    q))

(defun eijiro-search--query-pattern (query search-mode &optional target include-description)
  "Build core regex pattern from QUERY and SEARCH-MODE.
TARGET is one of nil/`headword'/`rg'.
When INCLUDE-DESCRIPTION is non-nil, build pattern for description search."
  (pcase search-mode
    ("text" (regexp-quote query))
    ("fuzzy" (eijiro-search--fuzzy-pattern query))
    ("regex" (if (eq target 'rg)
                 (eijiro-search--regex-pattern-for-rg query include-description)
               (eijiro-search--regex-pattern-for-headword query)))
    (_ (regexp-quote query))))

(defun eijiro-search--rg-args (query search-mode case-sensitive &optional include-description)
  "Build ripgrep args for QUERY with SEARCH-MODE and CASE-SENSITIVE.
When INCLUDE-DESCRIPTION is non-nil, adjust regex expansion for descriptions."
  (append
   (list "--no-heading"
         "--line-number"
         "--max-count" (number-to-string eijiro-search-max-results))
   (unless case-sensitive '("-i"))
   (list "-e" (eijiro-search--query-pattern query search-mode 'rg include-description)
         "--"
         eijiro-search-dictionary-file)))

(defun eijiro-search--rg-args-with-pattern (pattern case-sensitive)
  "Build ripgrep args with raw PATTERN and CASE-SENSITIVE."
  (append
   (list "--no-heading"
         "--line-number"
         "--max-count" (number-to-string eijiro-search-max-results))
   (unless case-sensitive '("-i"))
   (list "-e" pattern "--" eijiro-search-dictionary-file)))

(defun eijiro-search--match-in-string-p (pattern text case-sensitive)
  "Return non-nil when PATTERN matches TEXT using CASE-SENSITIVE."
  (let ((case-fold-search (not case-sensitive)))
    (string-match-p pattern text)))

(defun eijiro-search--normalize (text case-sensitive)
  "Normalize TEXT for matching with CASE-SENSITIVE."
  (if case-sensitive text (downcase text)))

(defun eijiro-search--headword-core (term)
  "Return TERM without trailing metadata blocks like `{名-1}`."
  (let ((s (string-trim-right (or term ""))))
    (while (string-match "\\(.*?\\)\\s-*{[^}]+}\\s-*\\'" s)
      (setq s (string-trim-right (match-string 1 s))))
    s))

(defun eijiro-search--contains-kind (term query)
  "Classify QUERY containment in TERM.
Return nil (no match), `boundary' (match touches boundary), or `embedded'."
  (let ((needle (regexp-quote (or query "")))
        (pos 0)
        (found-embedded nil))
    (catch 'result
      (while (and (not (string-empty-p query))
                  (string-match needle term pos))
        (let* ((beg (match-beginning 0))
               (end (match-end 0))
               (left-alnum (and (> beg 0)
                                (string-match-p "[[:alnum:]]"
                                                (string (aref term (1- beg))))))
               (right-alnum (and (< end (length term))
                                 (string-match-p "[[:alnum:]]"
                                                 (string (aref term end))))))
          (if (or (not left-alnum) (not right-alnum))
              (throw 'result 'boundary)
            (setq found-embedded t)))
        (setq pos (1+ (match-beginning 0))))
      (when found-embedded
        'embedded))))

(defun eijiro-search--fuzzy-score (query target case-sensitive)
  "Return fuzzy score for QUERY against TARGET with CASE-SENSITIVE.
Return nil if unmatched."
  (let* ((needle (eijiro-search--normalize (eijiro-search--fuzzy-needle query) case-sensitive))
         (haystack (eijiro-search--normalize (or target "") case-sensitive))
         (pos -1)
         (prev nil)
         (start nil)
         (score 1000)
         (matched t))
    (if (string-empty-p needle)
        nil
      (cl-loop for ch across needle
               do (let ((idx (cl-position ch haystack :start (1+ pos) :test #'=)))
                    (if (null idx)
                        (setq matched nil)
                      (unless start
                        (setq start idx))
                      (if prev
                          (let ((gap (- idx prev 1)))
                            (setq score (- score (* 2 gap)))
                            (when (= gap 0)
                              (setq score (+ score 8))))
                        (setq score (+ score 12)))
                      (when (or (= idx 0)
                                (not (string-match-p
                                      "[[:alnum:]]"
                                      (string (aref haystack (1- idx))))))
                        (setq score (+ score 6)))
                      (setq pos idx
                            prev idx))))
      (when matched
        (- score (* 3 (or start 0)))))))

(defun eijiro-search--run-command-lines (program args)
  "Run PROGRAM with ARGS and return output lines.
Exit status 1 (no match) is treated as empty result."
  (with-temp-buffer
    (let ((status (apply #'call-process program nil t nil args))
          (output nil))
      (cond
       ((or (eq status 0) (eq status 1))
        (setq output (split-string (buffer-string) "\n" t))
        output)
       (t
        (error "%s failed with status %s" program status))))))

(defun eijiro-search--extract-hit (raw-line)
  "Split RAW-LINE into (LINE-NUMBER . ENTRY-TEXT)."
  (if (string-match "\\`\\([0-9]+\\):\\(.*\\)\\'" raw-line)
      (cons (string-to-number (match-string 1 raw-line))
            (match-string 2 raw-line))
    (cons 0 raw-line)))

(defun eijiro-search--parse-entry (line line-number)
  "Parse dictionary LINE with LINE-NUMBER into plist."
  (let* ((body (if (string-prefix-p "■" line) (substring line 1) line))
         (entry (string-trim body))
         (term entry)
         (meaning ""))
    (when (string-match "\\`\\(.+?\\)\\s-*:\\s-*\\(.*\\)\\'" entry)
      (setq term (string-trim (match-string 1 entry)))
      (setq meaning (string-trim (match-string 2 entry))))
    (list :line-number line-number
          :term term
          :meaning meaning
          :raw entry)))

(defun eijiro-search--rank-entry (entry query case-sensitive)
  "Return rank number for ENTRY against QUERY with CASE-SENSITIVE.
Lower is better."
  (let* ((term (or (plist-get entry :term) ""))
         (core (eijiro-search--headword-core term))
         (q (or query ""))
         (term* (downcase term))
         (core* (downcase core))
         (q* (downcase q))
         (cs-kind (eijiro-search--contains-kind term q))
         (ci-kind (and (not case-sensitive)
                       (eijiro-search--contains-kind term* q*))))
    (cond
     ;; case-sensitive matches first
     ((string= term q) 0)
     ;; then normalized exact match
     ((and (not case-sensitive) (string= term* q*)) 1)
     ;; treat headword core with trailing {..} as normalized exact
     ((and (not case-sensitive) (string= core* q*)) 1)
     ;; then case-sensitive prefix / contains
     ((string-prefix-p q term) 2)
     ((eq cs-kind 'boundary) 3)
     ;; then normalized prefix / contains
     ((and (not case-sensitive) (string-prefix-p q* term*)) 4)
     ((eq ci-kind 'boundary) 5)
     ;; embedded match (inside a token) is less relevant
     ((eq cs-kind 'embedded) 6)
     ((eq ci-kind 'embedded) 7)
     (t 8))))

(defun eijiro-search--rank-tiebreak (entry query case-sensitive)
  "Return tie-break rank for ENTRY against QUERY with CASE-SENSITIVE.
Lower is better."
  (let* ((term (or (plist-get entry :term) ""))
         (core (eijiro-search--headword-core term))
         (q* (downcase (or query "")))
         (term* (downcase term))
         (core* (downcase core))
         (core-exact (and (not case-sensitive) (string= core* q*)))
         (term-exact (and (not case-sensitive) (string= term* q*))))
    ;; Prefer plain exact headword over metadata variants like "lisp  {名-1}".
    (if (and core-exact (not term-exact)) 1 0)))

(defun eijiro-search--sort-entries (entries query case-sensitive)
  "Sort ENTRIES by headword relevance against QUERY with CASE-SENSITIVE."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let ((ra (eijiro-search--rank-entry a query case-sensitive))
                (rb (eijiro-search--rank-entry b query case-sensitive)))
            (if (/= ra rb)
                (< ra rb)
              (let ((ta (eijiro-search--rank-tiebreak a query case-sensitive))
                    (tb (eijiro-search--rank-tiebreak b query case-sensitive)))
                (if (/= ta tb)
                    (< ta tb)
                  (< (plist-get a :line-number) (plist-get b :line-number)))))))))

(defun eijiro-search--fuzzy-sort-entries (entries query include-description case-sensitive)
  "Filter and sort ENTRIES by fuzzy score for QUERY.
When INCLUDE-DESCRIPTION is non-nil, score against raw entry text.
Use CASE-SENSITIVE for matching."
  (let ((scored nil))
    (dolist (entry entries)
      (let* ((target (if include-description
                         (plist-get entry :raw)
                       (plist-get entry :term)))
             (score (eijiro-search--fuzzy-score query target case-sensitive)))
        (when score
          (push (cons entry score) scored))))
    (mapcar
     #'car
     (sort scored
           (lambda (a b)
             (let ((sa (cdr a))
                   (sb (cdr b))
                   (ea (car a))
                   (eb (car b)))
               (if (/= sa sb)
                   (> sa sb)
                 (let ((ra (eijiro-search--rank-entry ea query case-sensitive))
                       (rb (eijiro-search--rank-entry eb query case-sensitive)))
                   (if (/= ra rb)
                       (< ra rb)
                     (let ((ta (eijiro-search--rank-tiebreak ea query case-sensitive))
                           (tb (eijiro-search--rank-tiebreak eb query case-sensitive)))
                       (if (/= ta tb)
                           (< ta tb)
                         (< (plist-get ea :line-number)
                             (plist-get eb :line-number)))))))))))))

(defun eijiro-search--split-for-rows (text)
  "Split TEXT into display segments for stacked table rows.
The first element is the main text.  `■' starts a new row with marker kept.
`◆' starts a new row but the marker itself is not displayed."
  (let ((s (or text "")))
    (if (not (string-match "[■◆]" s))
        (list (string-trim s))
      (let ((rows (list (string-trim (substring s 0 (match-beginning 0)))))
            (pos (match-beginning 0)))
        (while (and (< pos (length s))
                    (string-match "[■◆]" s pos))
          (let* ((marker (aref s (match-beginning 0)))
                 (seg-start (1+ (match-beginning 0)))
                 (next (or (and (string-match "[■◆]" s seg-start)
                                (match-beginning 0))
                           (length s)))
                 (body (string-trim (substring s seg-start next))))
            (push (if (= marker ?■)
                      (if (string-prefix-p "・" body)
                          body
                        (concat "■" body))
                    body)
                  rows)
            (setq pos next)))
        (nreverse rows)))))

(defun eijiro-search--propertize-placeholders (text)
  "Apply `font-lock-variable-name-face' to placeholder markers in TEXT.
Targets are `__' and full-width `＿'."
  (let ((s (copy-sequence (or text "")))
        (pos 0))
    (while (string-match "\\(__\\|＿\\)" s pos)
      (add-face-text-property (match-beginning 0)
                              (match-end 0)
                              'font-lock-variable-name-face
                              nil
                              s)
      (setq pos (match-end 0)))
    s))

(defun eijiro-search--propertize-headword (text)
  "Apply dictionary-specific faces to headword TEXT."
  (let ((s (eijiro-search--propertize-placeholders text))
        (pos 0))
    (while (string-match "{[^}]+}" s pos)
      (add-face-text-property (match-beginning 0)
                              (match-end 0)
                              'font-lock-variable-use-face
                              nil
                              s)
      (setq pos (match-end 0)))
    s))

(defun eijiro-search--propertize-redirect-headword (text)
  "Apply redirect face to headword TEXT."
  (let ((s (eijiro-search--propertize-headword text)))
    (add-face-text-property 0 (length s) 'font-lock-builtin-face nil s)
    s))

(defun eijiro-search--with-help-echo (text tooltip)
  "Attach help-echo TOOLTIP to TEXT."
  (let ((s (copy-sequence (or text ""))))
    (add-text-properties 0 (length s) (list 'help-echo tooltip) s)
    s))

(defun eijiro-search--propertize-meaning (text)
  "Apply dictionary-specific faces to meaning TEXT."
  (let ((s (eijiro-search--propertize-placeholders text))
        (pos 0))
    (setq pos 0)
    (while (string-match "\\[US\\]" s pos)
      (add-text-properties (match-beginning 0)
                           (match-end 0)
                           '(display "🇺🇸")
                           s)
      (setq pos (match-end 0)))
    (setq pos 0)
    (while (string-match "\\[UK\\]" s pos)
      (add-text-properties (match-beginning 0)
                           (match-end 0)
                           '(display "🇬🇧")
                           s)
      (setq pos (match-end 0)))
    (setq pos 0)
    (while (string-match "《[^》]+》" s pos)
      (add-face-text-property (match-beginning 0)
                              (match-end 0)
                              'font-lock-function-name-face
                              nil
                              s)
      (setq pos (match-end 0)))
    (setq pos 0)
    (while (string-match "［[^］]+］" s pos)
      (add-face-text-property (match-beginning 0)
                              (match-end 0)
                              'font-lock-comment-face
                              nil
                              s)
      (setq pos (match-end 0)))
    (setq pos 0)
    (while (string-match "【[^】]+】" s pos)
      (add-face-text-property (match-beginning 0)
                              (match-end 0)
                              'font-lock-constant-face
                              nil
                              s)
      (setq pos (match-end 0)))
    (setq pos 0)
    (while (string-match "〈[^〉]+〉" s pos)
      (add-face-text-property (match-beginning 0)
                              (match-end 0)
                              'font-lock-type-face
                              nil
                              s)
      (setq pos (match-end 0)))
    (setq pos 0)
    (while (string-match "〔[^〕]+〕" s pos)
      (add-face-text-property (match-beginning 0)
                              (match-end 0)
                              'font-lock-keyword-face
                              nil
                              s)
      (setq pos (match-end 0)))
    (setq pos 0)
    (while (string-match "<→[^>]+>" s pos)
      (add-face-text-property (match-beginning 0)
                              (match-end 0)
                              'font-lock-builtin-face
                              nil
                              s)
      (setq pos (match-end 0)))
    s))

(defun eijiro-search--expand-entry-rows (entry &optional redirected)
  "Expand ENTRY into one or more table rows.
When REDIRECTED is non-nil, style headword as redirected."
  (let* ((terms (eijiro-search--split-for-rows (plist-get entry :term)))
         (meanings (eijiro-search--split-for-rows (plist-get entry :meaning)))
         (full-term (or (plist-get entry :term) ""))
         (count (max (length terms) (length meanings)))
         (rows nil))
    (dotimes (i count)
      (push (list (if (< i (length terms))
                      (eijiro-search--with-help-echo
                       (if redirected
                           (eijiro-search--propertize-redirect-headword (nth i terms))
                         (eijiro-search--propertize-headword (nth i terms)))
                       full-term)
                    (if (= i 0)
                        ""
                      (vui-text (if (= i (1- count)) "└" "│")
                        :face 'line-number)))
                  (if (< i (length meanings))
                      (eijiro-search--propertize-meaning (nth i meanings))
                    ""))
            rows))
    (nreverse rows)))

(defun eijiro-search--run-rg-entries (query search-mode case-sensitive &optional include-description)
  "Run rg and parse entries for QUERY with SEARCH-MODE.
Use CASE-SENSITIVE and INCLUDE-DESCRIPTION when building the rg pattern."
  (mapcar (lambda (raw-line)
            (pcase-let* ((`(,line-number . ,line)
                          (eijiro-search--extract-hit raw-line)))
              (eijiro-search--parse-entry line line-number)))
          (eijiro-search--run-command-lines
           "rg"
           (eijiro-search--rg-args query search-mode case-sensitive include-description))))

(defun eijiro-search--run-rg-entries-with-pattern (pattern case-sensitive)
  "Run rg with raw PATTERN using CASE-SENSITIVE and parse entries."
  (mapcar (lambda (raw-line)
            (pcase-let* ((`(,line-number . ,line)
                          (eijiro-search--extract-hit raw-line)))
              (eijiro-search--parse-entry line line-number)))
          (eijiro-search--run-command-lines
           "rg"
           (eijiro-search--rg-args-with-pattern pattern case-sensitive))))

(defun eijiro-search--redirect-targets (entry)
  "Extract redirect targets from ENTRY meaning.
Returns a list of words found in <→...> markers."
  (let ((text (or (plist-get entry :meaning) ""))
        (pos 0)
        (targets nil))
    ;; <→foo> and <→foo style redirects.
    (while (string-match "<→\\([^>◆■]+\\)>?" text pos)
      (push (string-trim (match-string 1 text)) targets)
      (setq pos (min (length text) (max (1+ pos) (match-end 0)))))
    ;; 〈英〉→foo / →foo style redirects.
    (setq pos 0)
    (while (string-match
            "\\(?:^\\|[[:space:]]\\|[、。；;◆]\\)\\(?:〈[^〉]+〉\\)?→\\([^◆■]+\\)"
            text
            pos)
      (push (string-trim (match-string 1 text)) targets)
      (setq pos (min (length text) (max (1+ pos) (match-end 0)))))
    ;; 【参考】foo ; bar style references.
    (setq pos 0)
    (while (string-match "【参考】\\([^【◆■]+\\)" text pos)
      (let* ((raw (string-trim (match-string 1 text)))
             (refs (split-string raw "[;；]" t "[[:space:]\n\r\t]+")))
        (dolist (ref refs)
          (let ((r (string-trim ref)))
            (unless (string-empty-p r)
              (push r targets)))))
      (setq pos (min (length text) (max (1+ pos) (match-end 0)))))
    (nreverse targets)))

(defun eijiro-search--build-redirect-pattern (targets)
  "Build rg pattern for TARGETS.
Matches headword lines with optional trailing metadata blocks."
  (format "^■(%s)(?:[[:space:]]*\\{[^}]+\\})?[[:space:]]*:"
          (mapconcat #'regexp-quote targets "|")))

(defun eijiro-search--entry-normalized-keys (entry case-sensitive)
  "Return normalized lookup keys for ENTRY with CASE-SENSITIVE."
  (let* ((term (or (plist-get entry :term) ""))
         (core (eijiro-search--headword-core term))
         (a (eijiro-search--normalize term case-sensitive))
         (b (eijiro-search--normalize core case-sensitive)))
    (if (string= a b) (list a) (list a b))))

(defun eijiro-search--resolve-redirect-map (entries case-sensitive)
  "Resolve redirect targets from ENTRIES with CASE-SENSITIVE.
Return a hash table where each key is normalized target text and each value
is a resolved entry plist."
  (let* ((existing (make-hash-table :test 'equal))
         (targets nil))
    (dolist (entry entries)
      (dolist (key (eijiro-search--entry-normalized-keys entry case-sensitive))
        (puthash key t existing)))
    (dolist (entry entries)
      (dolist (target (eijiro-search--redirect-targets entry))
        (let ((key (eijiro-search--normalize target case-sensitive)))
          (unless (gethash key existing)
            (push target targets)))))
    (setq targets (delete-dups (nreverse targets)))
    (let ((resolved (make-hash-table :test 'equal)))
      (when targets
        (dolist (entry (eijiro-search--run-rg-entries-with-pattern
                        (eijiro-search--build-redirect-pattern targets)
                        case-sensitive))
          (dolist (key (eijiro-search--entry-normalized-keys entry case-sensitive))
            (unless (gethash key resolved)
              (puthash key entry resolved)))))
      resolved)))

(defun eijiro-search--headword-filter (entries pattern case-sensitive)
  "Filter ENTRIES by PATTERN against headword using CASE-SENSITIVE."
  (cl-remove-if-not
   (lambda (entry)
     (eijiro-search--match-in-string-p pattern
                                       (plist-get entry :term)
                                       case-sensitive))
   entries))

(defun eijiro-search--contains-exact-headword-p (entries query case-sensitive)
  "Return non-nil when ENTRIES include exact headword match for QUERY.
Use CASE-SENSITIVE for normalization."
  (let ((query* (eijiro-search--normalize query case-sensitive)))
    (cl-some (lambda (entry)
               (string= (eijiro-search--normalize (plist-get entry :term) case-sensitive)
                        query*))
             entries)))

(defun eijiro-search--merge-entries (primary secondary)
  "Merge PRIMARY and SECONDARY entries with deduplication by line number."
  (let ((seen (make-hash-table :test 'eql))
        (merged nil))
    (dolist (entry (append primary secondary))
      (let ((line (plist-get entry :line-number)))
        (unless (gethash line seen)
          (puthash line t seen)
          (push entry merged))))
    (nreverse merged)))

(defun eijiro-search--search (query search-mode include-description case-sensitive)
  "Search QUERY with SEARCH-MODE.
When INCLUDE-DESCRIPTION is non-nil, include meanings and descriptions.
Use CASE-SENSITIVE for matching."
  (unless (executable-find "rg")
    (error "RG is required but was not found"))
  (let* ((pattern (eijiro-search--query-pattern query search-mode 'headword))
         (primary-all (eijiro-search--run-rg-entries query search-mode case-sensitive include-description))
         (primary (if include-description
                      primary-all
                    (eijiro-search--headword-filter primary-all pattern case-sensitive)))
         (needs-prefix-refine (and (not (string= search-mode "regex"))
                                   (or (>= (length primary-all) eijiro-search-max-results)
                                       (not (eijiro-search--contains-exact-headword-p
                                             primary query case-sensitive)))))
         (merged (if needs-prefix-refine
                     (let* ((prefix-headword-pattern
                             (format "^■%s" (regexp-quote query)))
                            (prefix-all
                             (eijiro-search--run-rg-entries-with-pattern
                              prefix-headword-pattern
                              case-sensitive))
                            (prefix-pattern (format "^%s" (regexp-quote query)))
                            (prefix (eijiro-search--headword-filter
                                     prefix-all prefix-pattern case-sensitive)))
                       (eijiro-search--merge-entries primary prefix))
                   primary))
         (sorted (if (string= search-mode "fuzzy")
                     (eijiro-search--fuzzy-sort-entries
                      merged query include-description case-sensitive)
                   (eijiro-search--sort-entries merged query case-sensitive))))
    (if (> (length sorted) eijiro-search-max-results)
        (cl-subseq sorted 0 eijiro-search-max-results)
      sorted)))

(defun eijiro-search--result-rows (entries redirect-map case-sensitive)
  "Convert ENTRIES to table rows using REDIRECT-MAP and CASE-SENSITIVE."
  (let ((rows nil))
    (dolist (entry entries)
      (setq rows (nconc rows (eijiro-search--expand-entry-rows entry)))
      (dolist (target (eijiro-search--redirect-targets entry))
        (let ((resolved (gethash (eijiro-search--normalize target case-sensitive)
                                 redirect-map)))
          (when resolved
            (setq rows (nconc rows (eijiro-search--expand-entry-rows resolved t)))))))
    rows))

(defun eijiro-search--result-view (entries redirect-map case-sensitive)
  "Render result table from ENTRIES and REDIRECT-MAP with CASE-SENSITIVE."
  (if (null entries)
      (vui-text "No matching entries." :face 'shadow)
    (vui-table
     :columns `((:header "Headword"
                 :width ,eijiro-search-headword-max-width
                 :grow nil
                 :truncate t)
                (:header "Meaning" :min-width 48))
     :rows (eijiro-search--result-rows entries redirect-map case-sensitive))))

(vui-defcomponent eijiro-search--app ()
  "EIJIRO search app."
  :state ((query "")
          (search-mode "text")
          (include-description nil)
          (case-sensitive nil)
          (entries nil)
          (redirect-map nil)
          (status "Enter a query."))
  :render
  (progn
    (vui-use-effect (query search-mode include-description case-sensitive)
      (let ((needle (string-trim (or query ""))))
        (if (string-empty-p needle)
            (progn
              (vui-set-state :entries nil)
              (vui-set-state :redirect-map nil)
              (vui-set-state :status "Enter a query."))
          (condition-case err
              (let ((current-entries (eijiro-search--search needle
                                                            search-mode
                                                            include-description
                                                            case-sensitive)))
                (vui-set-state :entries current-entries)
                (vui-set-state :redirect-map
                               (eijiro-search--resolve-redirect-map
                                current-entries
                                case-sensitive))
                (vui-set-state
                 :status
                 (format "\"%s\": %d hits (max %d)"
                         needle
                         (length current-entries)
                         eijiro-search-max-results)))
            (error
             (vui-set-state :entries nil)
             (vui-set-state :redirect-map nil)
             (vui-set-state :status (error-message-string err)))))))
    (vui-vstack
     :spacing 1
     (vui-text "EIJIRO Search" :face 'bold)
     (vui-text (format "File: %s" eijiro-search-dictionary-file) :face 'shadow)
     (vui-hstack
      :spacing 1
      (vui-text "Query:")
      (vui-field :size 48
                 :value query
                 :on-change (lambda (new-value)
                              (vui-set-state :query new-value))))
     (vui-hstack
      :spacing 2
      (vui-text "Search:")
      (vui-select :value search-mode
                  :options eijiro-search--mode-options
                  :prompt "Search mode:"
                  :on-change (lambda (new-value)
                               (vui-set-state :search-mode new-value))))
     (vui-checkbox
      :checked include-description
      :label "Include meanings/descriptions (default: headword only)"
      :on-change (lambda (new-value)
                   (vui-set-state :include-description new-value)))
     (vui-checkbox
      :checked case-sensitive
      :label "Case-sensitive (default: ignore case)"
      :on-change (lambda (new-value)
                   (vui-set-state :case-sensitive new-value)))
     (vui-text status)
     (eijiro-search--result-view entries redirect-map case-sensitive))))

;;;###autoload
(defun eijiro-search ()
  "Open the EIJIRO interactive search UI."
  (interactive)
  (eijiro-search--ensure-dictionary)
  (let ((buf (get-buffer eijiro-search--buffer-name)))
    (if (buffer-live-p buf)
        (pop-to-buffer buf)
      (vui-mount (vui-component 'eijiro-search--app)
                 eijiro-search--buffer-name)
      (with-current-buffer (get-buffer eijiro-search--buffer-name)
        (setq-local truncate-lines t)))))

(provide 'eijiro-search)
;;; eijiro-search.el ends here
