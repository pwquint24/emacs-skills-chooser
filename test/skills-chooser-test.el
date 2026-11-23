;;; skills-chooser-test.el --- Tests for Skills Chooser  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Behavior-driven tests for the implementation proposed in AGENTS.md.
;;
;; Besides the two public commands, these tests establish two small internal
;; contracts:
;;
;;   (skills-chooser--parse-front-matter STRING) => (:name NAME :description
;;   DESCRIPTION), with multiline descriptions normalized to one line.
;;
;;   (skills-chooser--inventory LIBRARY) => a deterministically sorted list of
;;   plists containing :name, :group, :directory, :source-directory,
;;   :skill-file, :description, and :destination.
;;
;; The versioned manifest is represented as
;;   (:version 1 :entries ((:id NAME :destination DIRECTORY :source PATH
;;                           :method link-or-copy) ...)).
;; Keeping that representation as printed data makes its safety properties
;; straightforward to test without evaluating anything.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'org)
(require 'org-element)

(add-to-list 'load-path
             (expand-file-name
              ".." (file-name-directory (or load-file-name buffer-file-name))))
(require 'skills-chooser)

;;;; Fixture and file helpers

(defun skills-chooser-test--write-file (path contents)
  "Write CONTENTS to PATH as UTF-8, creating its parents."
  (make-directory (file-name-directory path) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file path
      (insert contents)))
  path)

(defun skills-chooser-test--read-file (path)
  "Return the UTF-8 contents of PATH."
  (let ((coding-system-for-read 'utf-8-unix))
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string))))

(defun skills-chooser-test--skill (library group directory name description)
  "Add a basic skill to LIBRARY and return its absolute source directory.
GROUP and DIRECTORY determine the layout, while NAME and DESCRIPTION become
YAML front-matter values."
  (let* ((source (expand-file-name (concat group "/" directory) library))
         (skill-file (expand-file-name "SKILL.md" source)))
    (skills-chooser-test--write-file
     skill-file
     (format "---\nname: %s\ndescription: %s\n---\n\n# %s\n"
             name description name))
    source))

(defmacro skills-chooser-test--with-fixture (&rest body)
  "Run BODY in a temporary library and workspace.
Bind `library', `workspace', `list-file', `target-directory', and
`manifest-file' for use in BODY.  Everything is deleted on exit."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "skills-chooser-test-" t))
          (library (expand-file-name "skill library" root))
          (workspace (expand-file-name "workspace" root))
          (list-file (expand-file-name "skills-list.org" workspace))
          (target-directory (expand-file-name ".agents/skills" workspace))
          (manifest-file
           (expand-file-name ".skills-chooser-manifest.eld" target-directory))
          (skills-chooser-library-directory library)
          (skills-chooser-list-file "skills-list.org")
          (skills-chooser-target-directory ".agents/skills")
          (default-directory (file-name-as-directory workspace)))
     (make-directory library t)
     (make-directory workspace t)
     (unwind-protect
         (progn ,@body)
       (delete-directory root t))))

(defun skills-chooser-test--update (workspace)
  "Update the test list for WORKSPACE."
  (skills-chooser-update workspace))

(defun skills-chooser-test--apply (workspace)
  "Apply the test list for WORKSPACE."
  (skills-chooser-apply workspace))

;;;; Org inspection and editing helpers

(defun skills-chooser-test--heading-ancestor (node)
  "Return NODE's containing headline, or nil."
  (let ((parent (org-element-property :parent node)))
    (while (and parent (not (eq (org-element-type parent) 'headline)))
      (setq parent (org-element-property :parent parent)))
    parent))

(defun skills-chooser-test--item-data (item)
  "Return test-friendly data for Org ITEM."
  (list
   :checkbox (org-element-property :checkbox item)
   :text (string-trim
          (org-element-interpret-data (org-element-contents item)))
   :links
   (org-element-map (org-element-contents item) 'link
     (lambda (link)
       (list :type (org-element-property :type link)
             :path (org-element-property :path link)
             :raw (org-element-property :raw-link link)
             :label (string-trim
                     (org-element-interpret-data
                      (org-element-contents link))))))))

(defun skills-chooser-test--parse-org (text)
  "Extract preamble methods, groups, items, and links from Org TEXT."
  (with-temp-buffer
    (insert text)
    (org-mode)
    (let ((tree (org-element-parse-buffer)))
      (list
       :methods
       (org-element-map tree 'item
         (lambda (item)
           (unless (skills-chooser-test--heading-ancestor item)
             (skills-chooser-test--item-data item))))
       :groups
       (org-element-map tree 'headline
         (lambda (headline)
           (when (= 1 (org-element-property :level headline))
             (list
              :name (org-element-property :raw-value headline)
              :items
              (org-element-map headline 'item
                #'skills-chooser-test--item-data)))))))))

(defun skills-chooser-test--group (configuration name)
  "Return group NAME from CONFIGURATION."
  (seq-find (lambda (group) (equal name (plist-get group :name)))
            (plist-get configuration :groups)))

(defun skills-chooser-test--skill-item (configuration group name)
  "Return skill item NAME in GROUP from CONFIGURATION."
  (seq-find
   (lambda (item)
     (seq-find (lambda (link) (equal name (plist-get link :label)))
               (plist-get item :links)))
   (plist-get (skills-chooser-test--group configuration group) :items)))

(defun skills-chooser-test--install-all-item (configuration group)
  "Return GROUP's Install All item from CONFIGURATION."
  (seq-find
   (lambda (item)
     (and (null (plist-get item :links))
          (string-match-p "\\`Install All\\'" (plist-get item :text))))
   (plist-get (skills-chooser-test--group configuration group) :items)))

(defun skills-chooser-test--set-checkbox (identifier state &optional after)
  "Set the checkbox on the line containing IDENTIFIER to STATE.
STATE is `on', `off', or `trans'.  If AFTER is non-nil, start searching after
that string.  Use Org's checkbox command for every state change."
  (unless (derived-mode-p 'org-mode)
    (org-mode))
  (goto-char (point-min))
  (when after
    (search-forward after))
  (search-forward identifier)
  (beginning-of-line)
  (if (eq state 'trans)
      (org-toggle-checkbox '(16))
    (let ((attempts 0))
      (while
          (not
           (eq state
               (let ((node (org-element-at-point)))
                 ;; Org deliberately returns the list itself at the start of
                 ;; its first item.  Move inside the prefix to inspect it.
                 (when (eq (org-element-type node) 'plain-list)
                   (setq node (org-element-at-point (1+ (point)))))
                 (org-element-property :checkbox node))))
        (when (> (cl-incf attempts) 2)
          (ert-fail (format "Could not set checkbox on %S to %S"
                            identifier state)))
        (org-toggle-checkbox)))))

(defun skills-chooser-test--set-checkbox-in-file
    (file identifier state &optional after)
  "Set IDENTIFIER's checkbox in FILE to STATE, optionally after AFTER."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (skills-chooser-test--set-checkbox identifier state after)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (point-min) (point-max) file nil 'silent))))

(defun skills-chooser-test--configuration (file)
  "Parse FILE using the test Org inspector."
  (skills-chooser-test--parse-org (skills-chooser-test--read-file file)))

(defun skills-chooser-test--visible-text ()
  "Return current buffer text without invisible portions."
  (let ((position (point-min))
        (end (point-max))
        pieces)
    (while (< position end)
      (let ((next (next-single-property-change position 'invisible nil end)))
        (unless (invisible-p position)
          (push (buffer-substring-no-properties position next) pieces))
        (setq position next)))
    (apply #'concat (nreverse pieces))))

;;;; Manifest helpers

(defun skills-chooser-test--manifest (file)
  "Read FILE, a fixture manifest, as printed Lisp data."
  (with-temp-buffer
    (insert-file-contents file)
    (read (current-buffer))))

(defun skills-chooser-test--manifest-entry (file name)
  "Return manifest entry NAME from FILE."
  (seq-find (lambda (entry) (equal name (plist-get entry :id)))
            (plist-get (skills-chooser-test--manifest file) :entries)))

;;;; Front matter and inventory

(ert-deftest skills-chooser-test-front-matter-yaml-and-unicode ()
  "Parse real YAML, normalize folds, and preserve Unicode."
  (let ((record
         (skills-chooser--parse-front-matter
          "---\nname: \"clojisr: core\"\ndescription: >-\n  Call R from Clojure,\n  including γ and 東京.\n---\nBody is not YAML: [unterminated\n")))
    (should (equal "clojisr: core" (plist-get record :name)))
    (should (equal "Call R from Clojure, including γ and 東京."
                   (plist-get record :description)))
    (should-not (string-match-p "[\n\r]" (plist-get record :description)))))

(ert-deftest skills-chooser-test-front-matter-rejects-invalid-input ()
  "Reject absent delimiters, malformed YAML, and bad field types."
  (dolist (contents
           '("name: clojisr\ndescription: No opening delimiter\n---\n"
             "---\nname: clojisr\ndescription: No closing delimiter\n"
             "---\nname: [unterminated\ndescription: Bad YAML\n---\n"
             "---\ndescription: Missing name\n---\n"
             "---\nname: clojisr\n---\n"
             "---\nname: [wrong, type]\ndescription: Valid\n---\n"
             "---\nname: clojisr\ndescription: [wrong, type]\n---\n"
             "---\nname: \"   \"\ndescription: Valid\n---\n"
             "---\nname: clojisr\ndescription: \"\"\n---\n"))
    (ert-info ((format "Contents: %S" contents) :prefix "Invalid input: ")
      (should-error (skills-chooser--parse-front-matter contents)))))

(ert-deftest skills-chooser-test-inventory-layout-records-and-sorting ()
  "Discover only immediate visible children and sort deterministically."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "Beta" "zeta" "zeta-name" "Last group")
    (skills-chooser-test--skill library "alpha" "beta" "beta-name" "Second skill")
    (let ((alpha-source
           (skills-chooser-test--skill
            library "alpha" "Alpha" "alpha-name" "First skill")))
      (skills-chooser-test--write-file
       (expand-file-name "nested/body.txt" alpha-source) "Skill content\n"))
    (skills-chooser-test--skill library ".hidden" "secret" "secret" "Hidden")
    (skills-chooser-test--skill library "alpha" ".secret" "secret" "Hidden")
    (skills-chooser-test--write-file
     (expand-file-name "alpha/ordinary-file") "Not a skill\n")
    (let* ((inventory (skills-chooser--inventory library))
           (alpha (nth 0 inventory))
           (beta (nth 1 inventory))
           (zeta (nth 2 inventory)))
      (should (= 3 (length inventory)))
      (should (equal '("alpha" "alpha" "Beta")
                     (mapcar (lambda (skill) (plist-get skill :group)) inventory)))
      (should (equal '("alpha-name" "beta-name" "zeta-name")
                     (mapcar (lambda (skill) (plist-get skill :name)) inventory)))
      (should (equal "alpha" (plist-get alpha :group)))
      (should (equal "Alpha" (plist-get alpha :directory)))
      (should (equal "Alpha" (plist-get alpha :destination)))
      (should (equal (expand-file-name "alpha/Alpha" library)
                     (plist-get alpha :source-directory)))
      (should (equal (expand-file-name "alpha/Alpha/SKILL.md" library)
                     (plist-get alpha :skill-file)))
      (should (equal "First skill" (plist-get alpha :description)))
      (should (equal "beta-name" (plist-get beta :name)))
      (should (equal "zeta-name" (plist-get zeta :name)))
      (should (cl-every #'file-name-absolute-p
                        (mapcar (lambda (skill) (plist-get skill :skill-file))
                                inventory))))))

(ert-deftest skills-chooser-test-validation-errors-do-not-replace-list ()
  "Report malformed skills together and leave an existing list untouched."
  (skills-chooser-test--with-fixture
    (let ((original "# Original configuration: do not replace\n"))
      (skills-chooser-test--write-file list-file original)
      (skills-chooser-test--write-file
       (expand-file-name "group/01-no-front/SKILL.md" library)
       "name: missing front matter\n")
      (skills-chooser-test--write-file
       (expand-file-name "group/02-no-close/SKILL.md" library)
       "---\nname: no-close\ndescription: Missing close\n")
      (skills-chooser-test--write-file
       (expand-file-name "group/03-bad-yaml/SKILL.md" library)
       "---\nname: [unterminated\ndescription: Bad YAML\n---\n")
      (skills-chooser-test--write-file
       (expand-file-name "group/04-wrong-type/SKILL.md" library)
       "---\nname: wrong-type\ndescription: [wrong, type]\n---\n")
      (make-directory (expand-file-name "group/05-no-skill-file" library) t)
      (let ((error-data (should-error (skills-chooser-test--update workspace))))
        (dolist (directory '("01-no-front" "02-no-close" "03-bad-yaml"
                             "04-wrong-type" "05-no-skill-file"))
          (should (string-match-p
                   (regexp-quote directory)
                   (error-message-string error-data)))))
      (should (equal original (skills-chooser-test--read-file list-file)))
      (should-not (file-exists-p manifest-file)))))

;;;; Creating and refreshing the Org configuration

(ert-deftest skills-chooser-test-update-generates-org-element-document ()
  "Create one method item, ordered groups, Install All, and file links."
  (skills-chooser-test--with-fixture
    (let ((clojisr (skills-chooser-test--skill
                    library "clojure" "clojisr" "clojisr" "Call R from Clojure."))
          (plotting (skills-chooser-test--skill
                     library "clojure" "clojisr-plotting" "clojisr-plotting"
                     "Render R plots from Clojure.")))
      (skills-chooser-test--skill
       library "wolfram" "wolframite" "wolframite" "Drive a Wolfram kernel.")
      (let ((serializer (symbol-function 'org-element-interpret-data))
            (serializer-calls 0))
        (cl-letf (((symbol-function 'org-element-interpret-data)
                   (lambda (&rest arguments)
                     (cl-incf serializer-calls)
                     (apply serializer arguments))))
          (should (equal list-file (skills-chooser-test--update workspace))))
        (should (> serializer-calls 0)))
      (let* ((before (skills-chooser-test--read-file list-file))
             (configuration (skills-chooser-test--parse-org before))
             (methods (plist-get configuration :methods))
             (clojure (skills-chooser-test--group configuration "clojure"))
             (clojisr-item
              (skills-chooser-test--skill-item configuration "clojure" "clojisr"))
             (plotting-item
              (skills-chooser-test--skill-item
               configuration "clojure" "clojisr-plotting"))
             (clojisr-link (car (plist-get clojisr-item :links)))
             (plotting-link (car (plist-get plotting-item :links))))
        (should (= 1 (length methods)))
        (should (eq 'off (plist-get (car methods) :checkbox)))
        (should (string-match-p "Copy skills instead of linking"
                                (plist-get (car methods) :text)))
        (should (equal '("clojure" "wolfram")
                       (mapcar (lambda (group) (plist-get group :name))
                               (plist-get configuration :groups))))
        (should (eq 'off (plist-get (skills-chooser-test--install-all-item
                                     configuration "clojure")
                                    :checkbox)))
        (should (= 3 (length (plist-get clojure :items))))
        (should (eq 'off (plist-get clojisr-item :checkbox)))
        (should (string-match-p "\\`Call R from Clojure\\."
                                (plist-get clojisr-item :text)))
        (should (equal "file" (plist-get clojisr-link :type)))
        (should (equal (expand-file-name "SKILL.md" clojisr)
                       (plist-get clojisr-link :path)))
        (should (equal "clojisr" (plist-get clojisr-link :label)))
        (should (equal (expand-file-name "SKILL.md" plotting)
                       (plist-get plotting-link :path)))
        (should-not (string-match-p "Copy skills instead of linking"
                                    (plist-get clojisr-item :text)))
        (should-not (string-match-p ":PROPERTIES:" before))
        (should-not (string-match-p "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}"
                                    before))
        ;; Re-parsing and an unchanged refresh must preserve the same document.
        (should (equal configuration
                       (skills-chooser-test--parse-org
                        (org-element-interpret-data
                         (with-temp-buffer
                           (insert before)
                           (org-mode)
                           (org-element-parse-buffer))))))
        (skills-chooser-test--update workspace)
        (should (equal before (skills-chooser-test--read-file list-file)))))))

(ert-deftest skills-chooser-test-update-hides-link-targets-descriptively ()
  "Descriptive display exposes descriptions and labels, not SKILL.md paths."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill
     library "clojure" "clojisr" "clojisr" "Call R from Clojure.")
    (skills-chooser-test--update workspace)
    (with-temp-buffer
      (insert-file-contents list-file)
      (org-mode)
      (setq-local org-link-descriptive t)
      (font-lock-ensure)
      (let ((visible (skills-chooser-test--visible-text)))
        (should (string-match-p "Call R from Clojure\\. clojisr" visible))
        (should-not (string-match-p "SKILL\\.md" visible))
        (should-not (string-match-p (regexp-quote library) visible))))))

(ert-deftest skills-chooser-test-update-keeps-link-display-buffer-local ()
  "Refresh enables descriptive links locally without changing the global value."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--update workspace)
    (let ((buffer (find-file-noselect list-file))
          (org-link-descriptive nil)
          (default-before (default-toplevel-value 'org-link-descriptive)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (setq-local org-link-descriptive nil))
            (skills-chooser-test--update workspace)
            (with-current-buffer buffer
              (should (local-variable-p 'org-link-descriptive))
              (should (eq t org-link-descriptive)))
            (should (null org-link-descriptive))
            (should (equal default-before
                           (default-toplevel-value 'org-link-descriptive))))
        (kill-buffer buffer)))))

(ert-deftest skills-chooser-test-refresh-merges-by-global-yaml-name ()
  "Preserve choices across moves, update metadata, and drop removed skills."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill
     library "old-group" "old-directory" "stable-name" "Old description")
    (skills-chooser-test--skill
     library "old-group" "removed" "removed-name" "Removed skill")
    (skills-chooser-test--update workspace)
    (skills-chooser-test--set-checkbox-in-file
     list-file "][stable-name]]" 'on)
    (skills-chooser-test--set-checkbox-in-file list-file "Copy skills" 'on)
    (delete-directory (expand-file-name "old-group/old-directory" library) t)
    (delete-directory (expand-file-name "old-group/removed" library) t)
    (let ((moved (skills-chooser-test--skill
                  library "new-group" "new-directory" "stable-name"
                  "New λ description.")))
      (skills-chooser-test--skill
       library "new-group" "new-skill" "new-name" "New skill")
      (skills-chooser-test--update workspace)
      (let* ((configuration (skills-chooser-test--configuration list-file))
             (stable (skills-chooser-test--skill-item
                      configuration "new-group" "stable-name"))
             (new (skills-chooser-test--skill-item
                   configuration "new-group" "new-name"))
             (link (car (plist-get stable :links))))
        (should (eq 'on (plist-get stable :checkbox)))
        (should (eq 'off (plist-get new :checkbox)))
        (should (eq 'on (plist-get (car (plist-get configuration :methods))
                                   :checkbox)))
        (should (string-match-p "New λ description\\."
                                (plist-get stable :text)))
        (should (equal (expand-file-name "SKILL.md" moved)
                       (plist-get link :path)))
        (should (null (skills-chooser-test--group configuration "old-group")))
        (should (null (skills-chooser-test--skill-item
                       configuration "new-group" "removed-name")))))))

(ert-deftest skills-chooser-test-refresh-install-all-and-intermediate-states ()
  "Install All governs new children; intermediate states normalize to off."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--update workspace)
    (skills-chooser-test--set-checkbox-in-file list-file "Install All" 'on)
    (skills-chooser-test--skill library "group" "two" "two" "Two")
    (skills-chooser-test--update workspace)
    (let ((configuration (skills-chooser-test--configuration list-file)))
      (should (eq 'on (plist-get (skills-chooser-test--install-all-item
                                  configuration "group")
                                 :checkbox)))
      (should (eq 'on (plist-get (skills-chooser-test--skill-item
                                  configuration "group" "one")
                                 :checkbox)))
      (should (eq 'on (plist-get (skills-chooser-test--skill-item
                                  configuration "group" "two")
                                 :checkbox))))
    (skills-chooser-test--set-checkbox-in-file list-file "Install All" 'trans)
    (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'trans)
    (skills-chooser-test--set-checkbox-in-file list-file "Copy skills" 'trans)
    (skills-chooser-test--update workspace)
    (let ((configuration (skills-chooser-test--configuration list-file)))
      (should (eq 'off (plist-get (skills-chooser-test--install-all-item
                                   configuration "group")
                                  :checkbox)))
      (should (eq 'off (plist-get (skills-chooser-test--skill-item
                                   configuration "group" "one")
                                  :checkbox)))
      (should (eq 'off (plist-get (car (plist-get configuration :methods))
                                  :checkbox))))))

(ert-deftest skills-chooser-test-refresh-does-not-infer-install-all ()
  "All checked children do not implicitly check Install All."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--skill library "group" "two" "two" "Two")
    (skills-chooser-test--update workspace)
    (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
    (skills-chooser-test--set-checkbox-in-file list-file "][two]]" 'on)
    (skills-chooser-test--update workspace)
    (let ((configuration (skills-chooser-test--configuration list-file)))
      (should (eq 'off (plist-get (skills-chooser-test--install-all-item
                                   configuration "group")
                                  :checkbox)))
      (should (eq 'on (plist-get (skills-chooser-test--skill-item
                                  configuration "group" "one")
                                 :checkbox)))
      (should (eq 'on (plist-get (skills-chooser-test--skill-item
                                  configuration "group" "two")
                                 :checkbox))))))

(ert-deftest skills-chooser-test-refresh-inserts-missing-method-checkbox ()
  "A missing workspace method defaults to link and is restored by update."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--update workspace)
    (with-temp-buffer
      (insert-file-contents list-file)
      ;; Use the Org command to remove the checkbox itself, then remove this
      ;; now-ordinary preamble bullet to model an older hand-written file.
      (skills-chooser-test--set-checkbox "Copy skills" 'off)
      (org-toggle-checkbox '(4))
      (kill-whole-line)
      (write-region (point-min) (point-max) list-file nil 'silent))
    ;; Apply can consume the older file without a method item.
    (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
    (skills-chooser-test--apply workspace)
    (should (file-symlink-p (expand-file-name "one" target-directory)))
    (skills-chooser-test--update workspace)
    (let ((methods (plist-get (skills-chooser-test--configuration list-file)
                              :methods)))
      (should (= 1 (length methods)))
      (should (eq 'off (plist-get (car methods) :checkbox))))))

(ert-deftest skills-chooser-test-update-declining-save-is-non-destructive ()
  "Declining to save a modified visiting buffer aborts without changes."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--update workspace)
    (let* ((disk-before (skills-chooser-test--read-file list-file))
           (buffer (find-file-noselect list-file)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (skills-chooser-test--set-checkbox "][one]]" 'on)
              (let ((buffer-before (buffer-string)))
                (cl-letf (((symbol-function 'yes-or-no-p)
                           (lambda (&rest _) nil))
                          ((symbol-function 'y-or-n-p)
                           (lambda (&rest _) nil)))
                  (should-error (skills-chooser-test--update workspace)))
                (should (buffer-modified-p))
                (should (equal buffer-before (buffer-string)))))
            (should (equal disk-before (skills-chooser-test--read-file list-file))))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

;;;; Applying links and copies

(ert-deftest skills-chooser-test-apply-default-links-and-records-manifest ()
  "A new unchecked method creates absolute links and valid manifest data."
  (skills-chooser-test--with-fixture
    (let ((source (skills-chooser-test--skill
                   library "group" "skill directory" "skill-name" "A skill")))
      (skills-chooser-test--update workspace)
      (skills-chooser-test--set-checkbox-in-file list-file "][skill-name]]" 'on)
      (skills-chooser-test--apply workspace)
      (let ((destination (expand-file-name "skill directory" target-directory))
            (entry (skills-chooser-test--manifest-entry manifest-file "skill-name")))
        (should (equal (expand-file-name source) (file-symlink-p destination)))
        (should (= 1 (plist-get (skills-chooser-test--manifest manifest-file) :version)))
        (should (equal "skill directory" (plist-get entry :destination)))
        (should (equal (expand-file-name source) (plist-get entry :source)))
        (should (eq 'link (plist-get entry :method)))))))

(ert-deftest skills-chooser-test-apply-copies-refreshes-and-is-idempotent ()
  "Copy mode propagates edits/deletions and leaves equal trees untouched."
  (skills-chooser-test--with-fixture
    (let* ((source (skills-chooser-test--skill
                    library "group" "one" "one" "One"))
           (keep (expand-file-name "keep.txt" source))
           (obsolete (expand-file-name "obsolete.txt" source))
           (nested (expand-file-name "nested/value.txt" source)))
      (skills-chooser-test--write-file keep "old\n")
      (skills-chooser-test--write-file obsolete "remove me\n")
      (skills-chooser-test--write-file nested "nested\n")
      (skills-chooser-test--update workspace)
      (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
      (skills-chooser-test--set-checkbox-in-file list-file "Copy skills" 'on)
      (skills-chooser-test--apply workspace)
      (let* ((destination (expand-file-name "one" target-directory))
             (copied-keep (expand-file-name "keep.txt" destination))
             (copied-obsolete (expand-file-name "obsolete.txt" destination))
             (copied-nested (expand-file-name "nested/value.txt" destination)))
        (should (file-directory-p destination))
        (should-not (file-symlink-p destination))
        (should (equal "old\n" (skills-chooser-test--read-file copied-keep)))
        (should (file-exists-p copied-obsolete))
        (skills-chooser-test--write-file keep "new\n")
        (delete-file obsolete)
        (skills-chooser-test--write-file
         (expand-file-name "added.txt" source) "added\n")
        (skills-chooser-test--apply workspace)
        (should (equal "new\n" (skills-chooser-test--read-file copied-keep)))
        (should-not (file-exists-p copied-obsolete))
        (should (equal "added\n"
                       (skills-chooser-test--read-file
                        (expand-file-name "added.txt" destination))))
        (let ((old-time '(10000 0)))
          (set-file-times copied-keep old-time)
          (set-file-times copied-nested old-time)
          (skills-chooser-test--apply workspace)
          (should (time-equal-p old-time (file-attribute-modification-time
                                          (file-attributes copied-keep))))
          (should (time-equal-p old-time (file-attribute-modification-time
                                          (file-attributes copied-nested)))))))))

(ert-deftest skills-chooser-test-apply-link-idempotency-does-no-file-work ()
  "A second identical link apply performs no destructive or link operations."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--update workspace)
    (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
    (skills-chooser-test--apply workspace)
    (let ((manifest-before (skills-chooser-test--read-file manifest-file)))
      (cl-letf (((symbol-function 'delete-file)
                 (lambda (&rest _) (ert-fail "Unexpected delete-file")))
                ((symbol-function 'delete-directory)
                 (lambda (&rest _) (ert-fail "Unexpected delete-directory")))
                ((symbol-function 'make-symbolic-link)
                 (lambda (&rest _) (ert-fail "Unexpected make-symbolic-link")))
                ((symbol-function 'copy-directory)
                 (lambda (&rest _) (ert-fail "Unexpected copy-directory"))))
        (skills-chooser-test--apply workspace))
      (should (equal manifest-before
                     (skills-chooser-test--read-file manifest-file))))))

(ert-deftest skills-chooser-test-apply-removes-only-managed-selections ()
  "Unchecking and source disappearance remove managed entries, not user files."
  (skills-chooser-test--with-fixture
    (let ((one (skills-chooser-test--skill library "group" "one" "one" "One"))
          (two (skills-chooser-test--skill library "group" "two" "two" "Two")))
      (skills-chooser-test--update workspace)
      (skills-chooser-test--set-checkbox-in-file list-file "Install All" 'on)
      (skills-chooser-test--apply workspace)
      (let ((one-destination (expand-file-name "one" target-directory))
            (two-destination (expand-file-name "two" target-directory))
            (unmanaged-file (expand-file-name "user-file" target-directory))
            (unmanaged-directory (expand-file-name "user-directory" target-directory)))
        (skills-chooser-test--write-file unmanaged-file "Keep me\n")
        (skills-chooser-test--write-file
         (expand-file-name "sentinel" unmanaged-directory) "Keep me too\n")
        (skills-chooser-test--set-checkbox-in-file list-file "Install All" 'off)
        (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'off)
        (skills-chooser-test--set-checkbox-in-file list-file "][two]]" 'on)
        (skills-chooser-test--apply workspace)
        (should-not (file-exists-p one-destination))
        (should (file-symlink-p two-destination))
        (should (file-exists-p (expand-file-name "SKILL.md" one)))
        ;; Removing the source before refresh must not prevent managed cleanup.
        (delete-directory two t)
        (skills-chooser-test--update workspace)
        (skills-chooser-test--apply workspace)
        (should-not (file-exists-p two-destination))
        (should-not (file-symlink-p two-destination))
        (should (equal "Keep me\n" (skills-chooser-test--read-file unmanaged-file)))
        (should (equal "Keep me too\n"
                       (skills-chooser-test--read-file
                        (expand-file-name "sentinel" unmanaged-directory))))
        (should-not (plist-get (skills-chooser-test--manifest manifest-file) :entries))))))

(ert-deftest skills-chooser-test-apply-install-all-and-intermediate-states ()
  "Intermediate method means link; intermediate Install All yields to children."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--skill library "group" "two" "two" "Two")
    (skills-chooser-test--update workspace)
    (skills-chooser-test--set-checkbox-in-file list-file "Install All" 'on)
    (skills-chooser-test--set-checkbox-in-file list-file "Copy skills" 'on)
    (skills-chooser-test--apply workspace)
    (should (file-directory-p (expand-file-name "one" target-directory)))
    (should (file-directory-p (expand-file-name "two" target-directory)))
    (skills-chooser-test--set-checkbox-in-file list-file "Install All" 'trans)
    (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
    (skills-chooser-test--set-checkbox-in-file list-file "][two]]" 'trans)
    (skills-chooser-test--set-checkbox-in-file list-file "Copy skills" 'trans)
    (skills-chooser-test--apply workspace)
    (should (file-symlink-p (expand-file-name "one" target-directory)))
    (should-not (file-exists-p (expand-file-name "two" target-directory)))
    (should (eq 'link (plist-get (skills-chooser-test--manifest-entry manifest-file "one")
                                 :method)))
    (should (null (skills-chooser-test--manifest-entry manifest-file "two")))))

(ert-deftest skills-chooser-test-apply-workspace-method-toggle-replaces-all ()
  "Changing the one workspace checkbox changes every selected destination."
  (skills-chooser-test--with-fixture
    (let ((one (skills-chooser-test--skill library "group" "one" "one" "One"))
          (two (skills-chooser-test--skill library "group" "two" "two" "Two")))
      (skills-chooser-test--update workspace)
      (skills-chooser-test--set-checkbox-in-file list-file "Install All" 'on)
      (skills-chooser-test--apply workspace)
      (should (file-symlink-p (expand-file-name "one" target-directory)))
      (should (file-symlink-p (expand-file-name "two" target-directory)))
      (skills-chooser-test--set-checkbox-in-file list-file "Copy skills" 'on)
      (skills-chooser-test--apply workspace)
      (dolist (name '("one" "two"))
        (should-not (file-symlink-p (expand-file-name name target-directory)))
        (should (file-directory-p (expand-file-name name target-directory)))
        (should (eq 'copy (plist-get (skills-chooser-test--manifest-entry manifest-file name)
                                     :method))))
      (should (file-exists-p (expand-file-name "SKILL.md" one)))
      (should (file-exists-p (expand-file-name "SKILL.md" two)))
      (skills-chooser-test--set-checkbox-in-file list-file "Copy skills" 'off)
      (skills-chooser-test--apply workspace)
      (dolist (name '("one" "two"))
        (should (file-symlink-p (expand-file-name name target-directory)))
        (should (eq 'link (plist-get (skills-chooser-test--manifest-entry manifest-file name)
                                     :method)))))))

(ert-deftest skills-chooser-test-apply-uses-unsaved-visiting-buffer ()
  "Unsaved choices and method win without changing buffer or disk contents."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--skill library "group" "two" "two" "Two")
    (skills-chooser-test--update workspace)
    (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
    (let* ((disk-before (skills-chooser-test--read-file list-file))
           (buffer (find-file-noselect list-file)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (org-mode)
              (skills-chooser-test--set-checkbox "][one]]" 'off)
              (skills-chooser-test--set-checkbox "][two]]" 'on)
              (skills-chooser-test--set-checkbox "Copy skills" 'on)
              (should (buffer-modified-p)))
            (skills-chooser-test--apply workspace)
            (should-not (file-exists-p (expand-file-name "one" target-directory)))
            (let ((two (expand-file-name "two" target-directory)))
              (should (file-directory-p two))
              (should-not (file-symlink-p two)))
            (should (equal disk-before (skills-chooser-test--read-file list-file)))
            (with-current-buffer buffer
              (should (buffer-modified-p))
              (should (equal disk-before
                             (skills-chooser-test--read-file list-file)))))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

;;;; Preflight validation and conflict safety

(ert-deftest skills-chooser-test-apply-rejects-missing-and-stale-sources ()
  "Missing sources and stale descriptive links fail before installation."
  (skills-chooser-test--with-fixture
    (let* ((source (skills-chooser-test--skill library "group" "one" "one" "One"))
           (old-target (expand-file-name "SKILL.md" source)))
      (skills-chooser-test--update workspace)
      (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
      (with-temp-buffer
        (insert-file-contents list-file)
        (goto-char (point-min))
        (search-forward old-target)
        (replace-match (expand-file-name "unexpected/SKILL.md" library) t t)
        (write-region (point-min) (point-max) list-file nil 'silent))
      (let ((error-data (should-error (skills-chooser-test--apply workspace))))
        (should (string-match-p "skills-chooser-update"
                                (error-message-string error-data))))
      (should-not (file-exists-p (expand-file-name "one" target-directory)))
      ;; Restore the correct target, then remove the selected source itself.
      (with-temp-buffer
        (insert-file-contents list-file)
        (goto-char (point-min))
        (search-forward (expand-file-name "unexpected/SKILL.md" library))
        (replace-match old-target t t)
        (write-region (point-min) (point-max) list-file nil 'silent))
      (delete-directory source t)
      (let ((error-data (should-error (skills-chooser-test--apply workspace))))
        (should (string-match-p "skills-chooser-update"
                                (error-message-string error-data))))
      (should-not (file-exists-p (expand-file-name "one" target-directory)))
      (should-not (file-exists-p manifest-file)))))

(ert-deftest skills-chooser-test-apply-rejects-duplicate-method-and-titles ()
  "Duplicate workspace methods and duplicate global titles are invalid."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--update workspace)
    (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
    (let ((valid (skills-chooser-test--read-file list-file)))
      (with-temp-buffer
        (insert valid)
        (goto-char (point-min))
        (search-forward "Copy skills instead of linking")
        (beginning-of-line)
        (insert (buffer-substring-no-properties
                 (line-beginning-position) (line-end-position))
                "\n")
        (write-region (point-min) (point-max) list-file nil 'silent))
      (let ((error-data (should-error (skills-chooser-test--apply workspace))))
        (should (string-match-p "Copy skills\\|method"
                                (error-message-string error-data))))
      (should-not (file-exists-p (expand-file-name "one" target-directory)))
      ;; Restore the valid baseline directly; update is not an error-recovery UI.
      (skills-chooser-test--write-file list-file valid)
      (with-temp-buffer
        (insert valid)
        (goto-char (point-min))
        (search-forward "][one]]")
        (beginning-of-line)
        (insert (buffer-substring-no-properties
                 (line-beginning-position) (line-end-position))
                "\n")
        (write-region (point-min) (point-max) list-file nil 'silent))
      (let ((error-data (should-error (skills-chooser-test--apply workspace))))
        (should (string-match-p "duplicate\\|Duplicate\\|one"
                                (error-message-string error-data))))
      (should-not (file-exists-p (expand-file-name "one" target-directory)))
      (should-not (file-exists-p manifest-file)))))

(ert-deftest skills-chooser-test-apply-rejects-malformed-skill-item ()
  "A selected item needs a description and a descriptive skill link."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--update workspace)
    (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
    (with-temp-buffer
      (insert-file-contents list-file)
      (goto-char (point-min))
      ;; Target the skill link by label: the preamble also contains a
      ;; descriptive link to the library, so a bare "[[" search is ambiguous.
      (search-forward "][one]]")
      (let ((end (match-end 0)))
        (search-backward "[[")
        (delete-region (match-beginning 0) end))
      (write-region (point-min) (point-max) list-file nil 'silent))
    (let ((error-data (should-error (skills-chooser-test--apply workspace))))
      (should (string-match-p "link\\|description"
                              (error-message-string error-data))))
    (should-not (file-exists-p (expand-file-name "one" target-directory)))))

(ert-deftest skills-chooser-test-apply-invalid-manifest-aborts-before-changes ()
  "Malformed or executable reader forms in the manifest are never trusted."
  (skills-chooser-test--with-fixture
    (skills-chooser-test--skill library "group" "one" "one" "One")
    (skills-chooser-test--update workspace)
    (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
    (let ((marker (expand-file-name "manifest-was-evaluated" root))
          (destination (expand-file-name "one" target-directory)))
      (skills-chooser-test--write-file
       manifest-file
       (format "(:version 1 :entries #.(progn (with-temp-file %S (insert %S)) nil))\n"
               marker "bad"))
      (should-error (skills-chooser-test--apply workspace))
      (should-not (file-exists-p marker))
      (should-not (file-exists-p destination))
      (skills-chooser-test--write-file manifest-file "(:version 1 :entries")
      (should-error (skills-chooser-test--apply workspace))
      (should-not (file-exists-p destination)))))

(ert-deftest skills-chooser-test-apply-preserves-all-unmanaged-conflicts ()
  "Preflight reports unmanaged files, directories, and wrong links safely."
  (skills-chooser-test--with-fixture
    (let ((one (skills-chooser-test--skill library "group" "one" "one" "One")))
      (skills-chooser-test--skill library "group" "two" "two" "Two")
      (skills-chooser-test--skill library "group" "three" "three" "Three")
      (skills-chooser-test--update workspace)
      (skills-chooser-test--set-checkbox-in-file list-file "Install All" 'on)
      (let ((one-destination (expand-file-name "one" target-directory))
            (two-destination (expand-file-name "two" target-directory))
            (three-destination (expand-file-name "three" target-directory)))
        (skills-chooser-test--write-file one-destination "Unmanaged file\n")
        (skills-chooser-test--write-file
         (expand-file-name "sentinel" two-destination) "Unmanaged directory\n")
        (make-symbolic-link one three-destination)
        (should-error (skills-chooser-test--apply workspace))
        (should (equal "Unmanaged file\n"
                       (skills-chooser-test--read-file one-destination)))
        (should (equal "Unmanaged directory\n"
                       (skills-chooser-test--read-file
                        (expand-file-name "sentinel" two-destination))))
        (should (equal (expand-file-name one) (file-symlink-p three-destination)))
        (should-not (file-exists-p manifest-file))))))

(ert-deftest skills-chooser-test-apply-adopts-exact-expected-symlink ()
  "An exact pre-existing expected link is adopted and recorded."
  (skills-chooser-test--with-fixture
    (let ((source (skills-chooser-test--skill library "group" "one" "one" "One")))
      (skills-chooser-test--update workspace)
      (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
      (make-directory target-directory t)
      (make-symbolic-link source (expand-file-name "one" target-directory))
      (skills-chooser-test--apply workspace)
      (should (equal (expand-file-name source)
                     (file-symlink-p (expand-file-name "one" target-directory))))
      (let ((entry (skills-chooser-test--manifest-entry manifest-file "one")))
        (should entry)
        (should (eq 'link (plist-get entry :method)))
        (should (equal (expand-file-name source) (plist-get entry :source)))))))

(ert-deftest skills-chooser-test-apply-refuses-tampered-managed-destination ()
  "A managed type mismatch is a conflict, not permission to delete a directory."
  (skills-chooser-test--with-fixture
    (let ((source (skills-chooser-test--skill library "group" "one" "one" "One")))
      (skills-chooser-test--update workspace)
      (skills-chooser-test--set-checkbox-in-file list-file "][one]]" 'on)
      (skills-chooser-test--apply workspace)
      (let ((destination (expand-file-name "one" target-directory)))
        (delete-file destination)
        (skills-chooser-test--write-file
         (expand-file-name "sentinel" destination) "Do not delete\n")
        (should-error (skills-chooser-test--apply workspace))
        (should (equal "Do not delete\n"
                       (skills-chooser-test--read-file
                        (expand-file-name "sentinel" destination))))
        (should (file-exists-p (expand-file-name "SKILL.md" source)))))))

(provide 'skills-chooser-test)
;;; skills-chooser-test.el ends here
