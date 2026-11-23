;;; skills-chooser.el --- Manage project skills with Org checkboxes -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Skills Chooser contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (yaml "1.2.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/example/skills-chooser

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Create and refresh an Org list from a grouped library of AI skills, then
;; link or copy selected skills into the current project.  See README.md for
;; the library layout and the two commands `skills-chooser-update' and
;; `skills-chooser-apply'.

;;; Code:

(require 'cl-lib)
(require 'files)
(require 'org)
(require 'org-element)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'yaml)

;;;; Customization, constants, and path helpers

(defgroup skills-chooser nil
  "Choose and install AI skills from a grouped library."
  :group 'tools
  :prefix "skills-chooser-")

(defcustom skills-chooser-library-directory nil
  "Root directory of the grouped skill library.
When nil, `skills-chooser-update' prompts for a directory and offers to save
it as a customization."
  :type '(choice (const :tag "Ask when updating" nil) directory)
  :group 'skills-chooser)

(defcustom skills-chooser-list-file "skills-list.org"
  "Org configuration file name, relative to the workspace root."
  :type 'string
  :group 'skills-chooser)

(defcustom skills-chooser-target-directory ".agents/skills"
  "Local skills directory name, relative to the workspace root."
  :type 'string
  :group 'skills-chooser)

(defconst skills-chooser--manifest-name ".skills-chooser-manifest.eld"
  "Base name of the Skills Chooser manifest.")

(defconst skills-chooser--method-label
  "Copy skills instead of linking (whole workspace)"
  "Text of the workspace-wide installation method item.")

(defconst skills-chooser--install-all-label "Install All"
  "Text of each authoritative group selection item.")

(defun skills-chooser--workspace-root (&optional root)
  "Return ROOT or the current project root as an absolute directory.
Without ROOT or a current project, use `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or root
        (when-let* ((project (project-current nil)))
          (project-root project))
        default-directory))))

(defun skills-chooser--list-file (root)
  "Return the Org configuration path for workspace ROOT."
  (expand-file-name skills-chooser-list-file root))

(defun skills-chooser--target-directory (root)
  "Return the skill destination directory for workspace ROOT."
  (file-name-as-directory
   (expand-file-name skills-chooser-target-directory root)))

(defun skills-chooser--visiting-buffer (file)
  "Return a buffer visiting FILE, comparing canonical file names."
  (let ((name (file-truename file)))
    (seq-find
     (lambda (buffer)
       (when-let* ((visited (buffer-local-value 'buffer-file-name buffer)))
         (equal (file-truename visited) name)))
     (buffer-list))))

(defun skills-chooser--display-context (root library)
  "Display the workspace ROOT and skill LIBRARY being used."
  (message "Skills Chooser: workspace %s; library %s" root library))

(defun skills-chooser--library-directory (&optional prompt)
  "Return the configured library.
When it is unset, prompt for a directory if PROMPT is non-nil.  When
prompting, offer to save the result as a customization."
  (if skills-chooser-library-directory
      (file-name-as-directory
       (expand-file-name skills-chooser-library-directory))
    (unless prompt
      (user-error
       "Skills Chooser: set `skills-chooser-library-directory' or run update"))
    (let ((directory
           (file-name-as-directory
            (expand-file-name
             (read-directory-name "Skill library: " nil nil t)))))
      (setq skills-chooser-library-directory directory)
      (when (y-or-n-p "Save this skill library as a customization? ")
        (customize-save-variable 'skills-chooser-library-directory directory))
      directory)))

(defun skills-chooser--read-file (file)
  "Return the UTF-8 contents of FILE."
  (let ((coding-system-for-read 'utf-8-unix))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun skills-chooser--atomic-write (file contents &optional unchanged)
  "Atomically write CONTENTS to FILE.
If UNCHANGED is non-nil and FILE already has those contents, do nothing.
The replacement is created beside FILE before it is renamed into place."
  (unless (and unchanged
               (file-regular-p file)
               (equal contents (skills-chooser--read-file file)))
    (let ((parent (file-name-directory file))
          temporary)
      (make-directory parent t)
      (setq temporary (make-temp-file (expand-file-name ".skills-chooser-" parent)))
      (unwind-protect
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-buffer
              (insert contents)
              (write-region (point-min) (point-max) temporary nil 'silent))
            (rename-file temporary file t)
            (setq temporary nil))
        (when (and temporary (file-exists-p temporary))
          (delete-file temporary))))))

(defun skills-chooser--name< (left right)
  "Compare names LEFT and RIGHT case-insensitively, then exactly."
  (let ((folded-left (downcase left))
        (folded-right (downcase right)))
    (or (string-lessp folded-left folded-right)
        (and (string-equal folded-left folded-right)
             (string-lessp left right)))))

(defun skills-chooser--directory-children (directory)
  "Return sorted, visible, immediate directories below DIRECTORY."
  (sort
   (seq-filter
    (lambda (name)
      (and (not (member name '("." "..")))
           (not (string-prefix-p "." name))
           (file-directory-p (expand-file-name name directory))))
    (directory-files directory nil nil t))
   #'skills-chooser--name<))

;;;; Front matter and YAML validation

(defun skills-chooser--normalize-description (description)
  "Return DESCRIPTION as one trimmed, readable line."
  (string-trim (replace-regexp-in-string "[\t\n\r ]+" " " description t t)))

(defun skills-chooser--parse-front-matter (contents)
  "Parse YAML front matter in CONTENTS.
Return a plist with nonempty string :name and :description fields.
The opening delimiter must be the first line; only the front matter is passed
to the YAML parser."
  (let ((lines (mapcar (lambda (line) (string-remove-suffix "\r" line))
                       (split-string contents "\n"))))
    (unless (equal (car lines) "---")
      (user-error "Skills Chooser: front matter must start with ---"))
    (let ((end (cl-position-if (lambda (line) (member line '("---" "...")))
                               (cdr lines))))
      (unless end
        (user-error "Skills Chooser: front matter has no closing delimiter"))
      (let ((data
             (condition-case error-data
                 (yaml-parse-string
                  (mapconcat #'identity (seq-take (cdr lines) end) "\n")
                  :object-type 'alist)
               (error
                (user-error "Skills Chooser: invalid YAML front matter: %s"
                            (error-message-string error-data))))))
        (unless (listp data)
          (user-error "Skills Chooser: front matter must be a YAML mapping"))
        (let ((name (alist-get 'name data))
              (description (alist-get 'description data)))
          (unless (and (stringp name) (not (string-empty-p (string-trim name))))
            (user-error "Skills Chooser: YAML name must be a nonempty string"))
          (unless (and (stringp description)
                       (not (string-empty-p (string-trim description))))
            (user-error
             "Skills Chooser: YAML description must be a nonempty string"))
          (list :name (string-trim name)
                :description (skills-chooser--normalize-description description)))))))

;;;; Library inventory

(defun skills-chooser--inventory (library)
  "Return validated skill records found immediately below LIBRARY.
Each record identifies its group, source files, stable YAML name, display
metadata, and proposed destination.  All malformed skill directories are
reported together."
  (setq library (file-name-as-directory (expand-file-name library)))
  (unless (file-directory-p library)
    (user-error "Skills Chooser: library is not a directory: %s" library))
  (let (records errors)
    (dolist (group (skills-chooser--directory-children library))
      (let ((group-directory (expand-file-name group library)))
        (dolist (directory (skills-chooser--directory-children group-directory))
          (let* ((source (expand-file-name directory group-directory))
                 (skill-file (expand-file-name "SKILL.md" source)))
            (condition-case error-data
                (progn
                  (unless (and (file-regular-p skill-file)
                               (file-readable-p skill-file))
                    (user-error "Missing or unreadable SKILL.md"))
                  (let ((metadata
                         (skills-chooser--parse-front-matter
                          (skills-chooser--read-file skill-file))))
                    (push (list :name (plist-get metadata :name)
                                :group group
                                :directory directory
                                :source-directory (expand-file-name source)
                                :skill-file (expand-file-name skill-file)
                                :description (plist-get metadata :description)
                                :destination directory)
                          records)))
              (error
               (push (format "%s: %s" (expand-file-name source)
                             (error-message-string error-data))
                     errors)))))))
    (setq records (nreverse records)
          errors (nreverse errors))
    (let ((names (make-hash-table :test #'equal)))
      (dolist (record records)
        (let ((name (plist-get record :name)))
          (when (gethash name names)
            (push (format "%s: duplicate YAML name %s"
                          (plist-get record :source-directory) name)
                  errors))
          (puthash name t names))))
    (when errors
      (user-error "Skills Chooser: inventory validation failed:\n%s"
                  (mapconcat #'identity (nreverse errors) "\n")))
    records))

;;;; Org extraction and construction

(defun skills-chooser--headline-ancestor (node)
  "Return NODE's containing headline, if any."
  (let ((parent (org-element-property :parent node)))
    (while (and parent (not (eq (org-element-type parent) 'headline)))
      (setq parent (org-element-property :parent parent)))
    parent))

(defun skills-chooser--item-text (item)
  "Return the interpreted textual contents of Org ITEM."
  (string-trim
   (substring-no-properties
    (org-element-interpret-data (org-element-contents item)))))

(defun skills-chooser--checked-p (item)
  "Return non-nil only when Org ITEM has a checked checkbox."
  (eq (org-element-property :checkbox item) 'on))

(defun skills-chooser--skill-item (item group)
  "Extract a skill from Org ITEM in GROUP, or signal a structural error.
The stable name comes from its descriptive file-link label."
  (let* ((contents (org-element-contents item))
         (links (org-element-map contents 'link #'identity))
         (paragraphs (seq-filter
                      (lambda (node) (eq (org-element-type node) 'paragraph))
                      contents)))
    (unless (and (= 1 (length links))
                 (= 1 (length paragraphs))
                 (= 1 (length contents)))
      (user-error
       "Skills Chooser: item in group %s needs one description and one link"
       group))
    (let* ((link (car links))
           (paragraph (car paragraphs))
           (parts (org-element-contents paragraph))
           (position (cl-position link parts :test #'eq)))
      (unless (and position
                   (equal (org-element-property :type link) "file")
                   (eq (org-element-property :format link) 'bracket)
                   (org-element-contents link)
                   (org-element-property :path link))
        (user-error
         "Skills Chooser: item in group %s needs a descriptive file link"
         group))
      (let ((name (string-trim
                   (substring-no-properties
                    (org-element-interpret-data (org-element-contents link)))))
            (description
             (string-trim
              (substring-no-properties
               (org-element-interpret-data (seq-take parts position)))))
            (trailing
             (string-trim
              (substring-no-properties
               (org-element-interpret-data (nthcdr (1+ position) parts))))))
        (unless (and (not (string-empty-p name))
                     (not (string-empty-p description))
                     (string-empty-p trailing))
          (user-error
           "Skills Chooser: item %s in group %s needs a description before its link"
           name group))
        (list :name name
              :description description
              :skill-file (org-element-property :path link)
              :checked (skills-chooser--checked-p item))))))

(defun skills-chooser--configuration-from-tree (tree)
  "Return structured selections from parsed Org TREE.
Both empty and intermediate checkboxes are unselected.  A missing workspace
method means link; duplicate method items and skill names are invalid."
  (let* ((method-items
          (org-element-map tree 'item
            (lambda (item)
              (and (null (skills-chooser--headline-ancestor item))
                   (string-match-p
                    (regexp-quote skills-chooser--method-label)
                    (skills-chooser--item-text item))
                   item))))
         (method (if (and method-items (skills-chooser--checked-p (car method-items)))
                     'copy
                   'link))
         (groups
          (org-element-map tree 'headline
            (lambda (headline)
              (unless (= 1 (org-element-property :level headline))
                (user-error "Skills Chooser: only top-level group headings are valid"))
              (let* ((group (org-element-property :raw-value headline))
                     (items (org-element-map headline 'item #'identity)))
                (unless (and items
                             (equal (skills-chooser--item-text (car items))
                                    skills-chooser--install-all-label)
                             (null (org-element-map
                                    (org-element-contents (car items)) 'link
                                    #'identity)))
                  (user-error
                   "Skills Chooser: group %s must start with Install All" group))
                (list :group group
                      :install-all (skills-chooser--checked-p (car items))
                      :items (mapcar (lambda (item)
                                       (skills-chooser--skill-item item group))
                                     (cdr items))))))))
    (when (> (length method-items) 1)
      (user-error "Skills Chooser: duplicate workspace method checkboxes"))
    (let (group-names skill-names)
      (dolist (group groups)
        (when (member (plist-get group :group) group-names)
          (user-error "Skills Chooser: duplicate group %s"
                      (plist-get group :group)))
        (push (plist-get group :group) group-names)
        (dolist (item (plist-get group :items))
          (when (member (plist-get item :name) skill-names)
            (user-error "Skills Chooser: duplicate skill title %s"
                        (plist-get item :name)))
          (push (plist-get item :name) skill-names))))
    (list :method method :groups groups)))

(defun skills-chooser--parse-current-configuration ()
  "Parse and validate a Skills Chooser configuration in the current buffer."
  (skills-chooser--configuration-from-tree (org-element-parse-buffer)))

(defun skills-chooser--read-configuration (file)
  "Read FILE, preferring the current contents of a visiting buffer."
  (if-let* ((buffer (skills-chooser--visiting-buffer file)))
      (with-current-buffer buffer
        (list :configuration (skills-chooser--parse-current-configuration)
              :buffer buffer
              :unsaved (buffer-modified-p)))
    (unless (file-readable-p file)
      (user-error
       "Skills Chooser: no readable %s; run `skills-chooser-update'" file))
    (with-temp-buffer
      (insert (skills-chooser--read-file file))
      (org-mode)
      (list :configuration (skills-chooser--parse-current-configuration)
            :buffer nil
            :unsaved nil))))

(defun skills-chooser--read-disk-configuration (file)
  "Read and validate FILE's current on-disk Org configuration."
  (with-temp-buffer
    (insert (skills-chooser--read-file file))
    (org-mode)
    (skills-chooser--parse-current-configuration)))

(defun skills-chooser--configuration-items (configuration)
  "Return all skill item records in CONFIGURATION."
  (apply #'append (mapcar (lambda (group) (plist-get group :items))
                          (plist-get configuration :groups))))

(defun skills-chooser--org-item (checked before &optional link)
  "Construct an Org checkbox item containing BEFORE and optional LINK.
CHECKED selects [X], otherwise [ ] is constructed."
  (org-element-create
   'item
   (list :bullet "- " :checkbox (if checked 'on 'off)
         :pre-blank 0 :post-blank 0)
   (apply #'org-element-create 'paragraph nil
          (append (list before) (and link (list link)) (list "\n")))))

(defun skills-chooser--org-link (skill)
  "Construct the descriptive Org file link for SKILL."
  (let ((path (plist-get skill :skill-file)))
    (org-element-create
     'link
     (list :type "file" :type-explicit-p t :path path :format 'bracket
           :raw-link (concat "file:" path))
     (plist-get skill :name))))

(defun skills-chooser--org-group (skills previous-groups previous-items)
  "Construct a group with SKILLS, merging PREVIOUS-GROUPS and PREVIOUS-ITEMS."
  (let* ((name (plist-get (car skills) :group))
         (previous (seq-find
                    (lambda (old) (equal name (plist-get old :group)))
                    previous-groups))
         (install-all (and previous (plist-get previous :install-all)))
         (items
          (list (skills-chooser--org-item
                 install-all skills-chooser--install-all-label))))
    (dolist (skill skills)
      (let ((old (cdr (assoc (plist-get skill :name) previous-items))))
        (push (skills-chooser--org-item
               (or install-all (and old (plist-get old :checked)))
               (concat (plist-get skill :description) " ")
               (skills-chooser--org-link skill))
              items)))
    (org-element-create
     'headline
     (list :level 1 :raw-value name :title (list name)
           :pre-blank 1 :post-blank 0)
     (org-element-create
      'section (list :pre-blank 0 :post-blank 0)
      (apply #'org-element-create 'plain-list
             (list :type 'unordered :pre-blank 0 :post-blank 0)
             (nreverse items))))))

(defun skills-chooser--document (library inventory previous)
  "Construct a document for LIBRARY and INVENTORY using PREVIOUS choices.
The library is a descriptive link so its source path is hidden in rendered
text while remaining clickable in the generated header."
  (let* ((previous-groups (and previous (plist-get previous :groups)))
         (previous-items
          (mapcar (lambda (item) (cons (plist-get item :name) item))
                  (and previous (skills-chooser--configuration-items previous))))
         (method (if (and previous (eq (plist-get previous :method) 'copy)) t))
         (groups (delete-dups (mapcar (lambda (skill) (plist-get skill :group))
                                      inventory)))
         (library-path (file-name-as-directory library))
         (preamble
          (org-element-create
           'section (list :pre-blank 0 :post-blank 0)
           (org-element-create 'keyword (list :key "TITLE" :value "Project Skills"))
           (org-element-create 'keyword (list :key "STARTUP" :value "showall"))
           (org-element-create
            'comment
            (list :value
                  (concat
                   "Skills Chooser generated configuration; descriptions and order may be regenerated.\n"
                   "M-x skills-chooser-update refreshes the inventory; M-x skills-chooser-apply installs selections.\n"
                   "Checked means copy; empty or intermediate means link for the whole workspace.\n"
                   "Both commands display the current library and workspace paths.\n"
                   "Checked group-wide selection includes every current skill in that group.\n")))
           (org-element-create
            'paragraph nil "Current library: "
            (org-element-create
             'link (list :type "file" :type-explicit-p t :path library-path
                         :format 'bracket :raw-link (concat "file:" library-path))
             "skill library")
            "\n")))
         (method-list
          (org-element-create
           'section (list :pre-blank 0 :post-blank 0)
           (org-element-create
            'plain-list (list :type 'unordered :pre-blank 0 :post-blank 1)
            (skills-chooser--org-item method skills-chooser--method-label))))
         (group-nodes
          (mapcar
           (lambda (group)
             (skills-chooser--org-group
              (seq-filter (lambda (skill)
                            (equal group (plist-get skill :group)))
                          inventory)
              previous-groups previous-items))
           groups)))
    (apply #'org-element-create 'org-data nil
           (append (list preamble method-list) group-nodes))))

(defun skills-chooser--refresh-visiting-buffer (file)
  "Revert FILE's visiting buffer and enable descriptive links locally.
Do not start visiting FILE merely to configure link display."
  (when-let* ((buffer (skills-chooser--visiting-buffer file)))
    (with-current-buffer buffer
      (revert-buffer :ignore-auto :noconfirm :preserve-modes)
      (setq-local org-link-descriptive t)
      (when (derived-mode-p 'org-mode)
        (font-lock-flush)
        (font-lock-ensure)))))

;;;; Manifest and operation planning

(defun skills-chooser--valid-manifest-entry-p (entry)
  "Return non-nil if ENTRY has a safe version-1 manifest shape."
  (and (proper-list-p entry)
       (stringp (plist-get entry :id))
       (not (string-empty-p (plist-get entry :id)))
       (stringp (plist-get entry :destination))
       (not (string-empty-p (plist-get entry :destination)))
       (not (file-name-absolute-p (plist-get entry :destination)))
       (not (string-match-p "[/\\]" (plist-get entry :destination)))
       (not (member (plist-get entry :destination) '("." "..")))
       (stringp (plist-get entry :source))
       (file-name-absolute-p (plist-get entry :source))
       (memq (plist-get entry :method) '(link copy))))

(defun skills-chooser--read-manifest (file)
  "Read and validate printed manifest data from FILE without evaluating it."
  (if (not (file-exists-p file))
      (list :version 1 :entries nil)
    (condition-case error-data
        (with-temp-buffer
          (insert (skills-chooser--read-file file))
          (goto-char (point-min))
          ;; The manifest is printed data and must never be evaluated.  Emacs
          ;; rejects `#.' read syntax on its own; binding `read-circle' to nil
          ;; additionally rejects `#N=' cyclic data before it is constructed.
          (let ((read-circle nil))
            (let ((manifest (read (current-buffer))))
              (condition-case nil
                  (progn
                    (read (current-buffer))
                    (user-error "Additional data after manifest"))
                (end-of-file nil))
              (unless (and (proper-list-p manifest)
                           (equal 1 (plist-get manifest :version))
                           (proper-list-p (plist-get manifest :entries))
                           (cl-every #'skills-chooser--valid-manifest-entry-p
                                     (plist-get manifest :entries)))
                (user-error "Invalid version-1 manifest structure"))
              (let (ids destinations)
                (dolist (entry (plist-get manifest :entries))
                  (when (or (member (plist-get entry :id) ids)
                            (member (plist-get entry :destination) destinations))
                    (user-error "Duplicate manifest id or destination"))
                  (push (plist-get entry :id) ids)
                  (push (plist-get entry :destination) destinations)))
              manifest)))
      (error
       (user-error "Skills Chooser: invalid manifest %s: %s"
                   file (error-message-string error-data))))))

(defun skills-chooser--manifest-text (entries)
  "Serialize manifest ENTRIES deterministically as printed Lisp data."
  (let ((print-length nil)
        (print-level nil)
        (print-circle t))
    (concat
     (prin1-to-string
      (list :version 1
            :entries
            (sort (copy-sequence entries)
                  (lambda (left right)
                    (string-lessp (plist-get left :destination)
                                  (plist-get right :destination))))))
     "\n")))

(defun skills-chooser--same-link-p (path source)
  "Return non-nil when PATH is a symlink directly to SOURCE."
  (when-let* ((target (file-symlink-p path)))
    (equal target (expand-file-name source))))

(defun skills-chooser--actual-state (path)
  "Return `absent', `link', `directory', or `other' for PATH."
  (cond ((file-symlink-p path) 'link)
        ((file-directory-p path) 'directory)
        ((file-exists-p path) 'other)
        (t 'absent)))

(defun skills-chooser--source-safe-p (source destination)
  "Return non-nil unless SOURCE and DESTINATION recursively contain each other."
  (let ((source-name (file-name-as-directory (expand-file-name source)))
        (destination-name (file-name-as-directory (expand-file-name destination))))
    (not (or (string-prefix-p source-name destination-name)
             (string-prefix-p destination-name source-name)))))

(defun skills-chooser--desired-installations (configuration inventory)
  "Resolve selected names in CONFIGURATION against fresh INVENTORY.
Return records augmented with :method and :destination-path."
  (let ((groups (plist-get configuration :groups))
        (method (plist-get configuration :method))
        selected)
    (dolist (group groups)
      (when (plist-get group :install-all)
        (dolist (skill inventory)
          (when (equal (plist-get group :group) (plist-get skill :group))
            (cl-pushnew (plist-get skill :name) selected :test #'equal))))
      (dolist (item (plist-get group :items))
        (when (plist-get item :checked)
          (cl-pushnew (plist-get item :name) selected :test #'equal))))
    (dolist (name selected)
      (let ((skill (seq-find (lambda (record) (equal name (plist-get record :name)))
                             inventory)))
        (unless skill
          (user-error
           "Skills Chooser: selected source %s is missing; run `skills-chooser-update'"
           name))))
    (dolist (group groups)
      (dolist (item (plist-get group :items))
        (when (plist-get item :checked)
          (let* ((skill (seq-find
                         (lambda (record)
                           (equal (plist-get item :name) (plist-get record :name)))
                         inventory))
                 (target (plist-get item :skill-file)))
            (when (and skill
                       (not (and (stringp target)
                                 (file-name-absolute-p target)
                                 (equal (expand-file-name target)
                                        (plist-get skill :skill-file)))))
              (user-error
               "Skills Chooser: stale source link for %s; run `skills-chooser-update'"
               (plist-get item :name)))))))
    (mapcar
     (lambda (name)
       (let ((skill (seq-find (lambda (record) (equal name (plist-get record :name)))
                              inventory)))
         (append skill (list :method method))))
     (nreverse selected))))

(defun skills-chooser--plan (configuration inventory manifest target)
  "Return a fully validated synchronization plan for TARGET.
CONFIGURATION, INVENTORY, and MANIFEST determine selected and previously
managed destinations.  No filesystem modifications are made."
  (let* ((desired (skills-chooser--desired-installations configuration inventory))
         (old-entries (plist-get manifest :entries))
         conflicts operations)
    (let ((seen-destinations (make-hash-table :test #'equal)))
      (dolist (skill desired)
        (let* ((destination-name (plist-get skill :destination))
               (destination (expand-file-name destination-name target))
               (source (plist-get skill :source-directory))
               (other (gethash destination-name seen-destinations)))
          (plist-put skill :destination-path destination)
          (when (and other
                     (not (equal (plist-get skill :name) (plist-get other :name))))
            (push (format "%s: duplicate destination for selected skills %s and %s"
                          destination-name
                          (plist-get other :name)
                          (plist-get skill :name))
                  conflicts))
          (puthash destination-name skill seen-destinations)
          (unless (file-directory-p source)
            (push (format "%s: selected source has disappeared; run skills-chooser-update"
                        destination)
                  conflicts))
          (unless (eq (plist-get skill :method) 'link)
            (unless (skills-chooser--source-safe-p source destination)
              (push (format "%s: recursive source and destination" destination)
                    conflicts))))))
    (dolist (entry old-entries)
      (let* ((path (expand-file-name (plist-get entry :destination) target))
             (actual (skills-chooser--actual-state path)))
        (unless (eq actual 'absent)
          (pcase (plist-get entry :method)
            ('link
             (unless (and (eq actual 'link)
                          (skills-chooser--same-link-p
                           path (plist-get entry :source)))
               (push (format "%s: managed destination differs from its link record"
                             path)
                     conflicts)))
            ('copy
             (unless (eq actual 'directory)
               (push (format "%s: managed destination differs from its copy record"
                             path)
                     conflicts)))))))
    (dolist (skill desired)
      (let* ((destination (plist-get skill :destination-path))
             (source (plist-get skill :source-directory))
             (old (seq-find
                   (lambda (entry)
                     (equal (plist-get entry :destination)
                            (plist-get skill :destination)))
                   old-entries))
             (actual (skills-chooser--actual-state destination)))
        (if old
            (let (action)
              (pcase (plist-get skill :method)
                ('link
                 (setq action
                       (if (skills-chooser--same-link-p destination source)
                           'unchanged 'refresh)))
                ('copy
                 (setq action
                       (if (and (eq (plist-get old :method) 'copy)
                                (equal source (plist-get old :source))
                                (eq actual 'directory)
                                (skills-chooser--trees-equal-p source destination))
                           'unchanged 'refresh))))
              (push (list :action action :skill skill :old old) operations))
          (cond
           ((eq actual 'absent)
            (push (list :action 'install :skill skill) operations))
           ((and (eq (plist-get skill :method) 'link)
                 (skills-chooser--same-link-p destination source))
            (push (list :action 'adopt :skill skill) operations))
           (t
            (push (format "%s: unmanaged destination conflicts with selected skill %s"
                          destination (plist-get skill :name))
                  conflicts)
            (push (list :action 'conflict :skill skill) operations))))))
    (dolist (entry old-entries)
      (unless (seq-find (lambda (skill)
                          (equal (plist-get skill :destination)
                                 (plist-get entry :destination)))
                        desired)
        (push (list :action 'remove :old entry) operations)))
    (let ((ordered (nreverse operations)))
      (when conflicts
        (user-error "Skills Chooser: preflight failed; no changes made:\n%s"
                    (mapconcat #'identity (nreverse conflicts) "\n")))
      ;; Complete every managed removal before starting installations.
      (list :desired desired
            :operations
            (append (seq-filter (lambda (operation)
                                  (eq (plist-get operation :action) 'remove))
                                ordered)
                    (seq-remove (lambda (operation)
                                  (eq (plist-get operation :action) 'remove))
                                ordered))))))

;;;; Filesystem execution

(defun skills-chooser--tree-snapshot (root)
  "Return relative paths, file types, and content hashes below ROOT.
Symbolic links are compared by their targets and are never traversed."
  (let (snapshot)
    (cl-labels
        ((visit (directory)
           (dolist (name (sort (seq-remove
                                (lambda (entry) (member entry '("." "..")))
                                (directory-files directory nil nil t))
                               #'string-lessp))
             (let* ((path (expand-file-name name directory))
                    (relative (file-relative-name path root))
                    (link (file-symlink-p path)))
               (cond
                (link (push (list relative 'link link) snapshot))
                ((file-directory-p path)
                 (push (list relative 'directory) snapshot)
                 (visit path))
                ((file-regular-p path)
                 (push
                  (list relative 'file
                        (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally path)
                          (secure-hash 'sha256 (current-buffer))))
                  snapshot))
                (t (push (list relative 'other) snapshot)))))))
      (visit root))
    (nreverse snapshot)))

(defun skills-chooser--trees-equal-p (source destination)
  "Return non-nil when SOURCE and DESTINATION have identical complete trees."
  (equal (skills-chooser--tree-snapshot source)
         (skills-chooser--tree-snapshot destination)))

(defun skills-chooser--remove-managed (entry target)
  "Remove manifest ENTRY below TARGET after rechecking its actual type."
  (let ((path (expand-file-name (plist-get entry :destination) target))
        (method (plist-get entry :method)))
    (pcase (skills-chooser--actual-state path)
      ('absent nil)
      ('link
       (unless (and (eq method 'link)
                    (skills-chooser--same-link-p path (plist-get entry :source)))
         (user-error "Skills Chooser: refusing to remove altered managed link %s" path))
       (delete-file path))
      ('directory
       (unless (eq method 'copy)
         (user-error "Skills Chooser: refusing to remove altered managed copy %s" path))
       (delete-directory path t))
      (_ (user-error "Skills Chooser: refusing to remove unexpected path %s" path)))))

(defun skills-chooser--copy-tree (source destination)
  "Replace DESTINATION with a complete copy of SOURCE using a sibling temporary."
  (let ((temporary (make-temp-name
                    (expand-file-name ".skills-chooser-copy-"
                                      (file-name-directory destination)))))
    (unwind-protect
        (progn
          (copy-directory source temporary t t)
          (when (file-directory-p destination)
            (delete-directory destination t))
          (rename-file temporary destination t)
          (setq temporary nil))
      (when (and temporary (file-directory-p temporary))
        (delete-directory temporary t)))))

(defun skills-chooser--execute-plan (plan target)
  "Execute PLAN below TARGET and return installation result counts."
  (let ((linked 0) (copied 0) (refreshed 0) (removed 0) (unchanged 0))
    (dolist (operation (plist-get plan :operations))
      (let ((action (plist-get operation :action))
            (skill (plist-get operation :skill))
            (old (plist-get operation :old)))
        (condition-case error-data
            (pcase action
              ('remove
               (skills-chooser--remove-managed old target)
               (cl-incf removed))
              ((or 'unchanged 'adopt)
               (cl-incf unchanged))
              ((or 'install 'refresh)
               (when old (skills-chooser--remove-managed old target))
               (let ((source (plist-get skill :source-directory))
                     (destination (plist-get skill :destination-path)))
                 (make-directory (file-name-directory destination) t)
                 (if (eq (plist-get skill :method) 'link)
                     (progn
                       (make-symbolic-link (expand-file-name source) destination)
                       (if (eq action 'install) (cl-incf linked) (cl-incf refreshed)))
                   (skills-chooser--copy-tree source destination)
                   (if (eq action 'install) (cl-incf copied)
                     (cl-incf refreshed)))))
              (_ (user-error "Skills Chooser: unexpected planned action %s" action)))
          (error
           (user-error
            "Skills Chooser: operation %s failed for %s; inspect paths before rerunning: %s"
            action
            (or (plist-get skill :destination-path)
                (and old (expand-file-name (plist-get old :destination) target)))
            (error-message-string error-data))))))
    (list :linked linked :copied copied :refreshed refreshed
          :removed removed :unchanged unchanged)))

(defun skills-chooser--unmanaged-count (target entries)
  "Count unrelated immediate entries below TARGET, excluding manifest ENTRIES."
  (if (not (file-directory-p target))
      0
    (let ((managed (mapcar (lambda (entry) (plist-get entry :destination)) entries)))
      (length
       (seq-filter
        (lambda (name)
          (not (or (member name '("." ".."))
                   (equal name skills-chooser--manifest-name)
                   (member name managed))))
        (directory-files target nil nil t))))))

;;;; Commands and summaries

;;;###autoload
(defun skills-chooser-update (&optional root)
  "Create or refresh the skill list for workspace ROOT.
Without ROOT, use the current project root, falling back to
`default-directory'.  Preserve choices by globally unique YAML skill name and
atomically replace the generated Org file only after successful validation."
  (interactive)
  (let* ((workspace (skills-chooser--workspace-root root))
         (library (skills-chooser--library-directory (called-interactively-p 'interactive)))
         (list-file (skills-chooser--list-file workspace))
         (buffer (skills-chooser--visiting-buffer list-file)))
    (skills-chooser--display-context workspace library)
    (when (and buffer (buffer-modified-p buffer))
      (unless (yes-or-no-p (format "Save modified %s before refreshing? " list-file))
        (user-error "Skills Chooser: update aborted; buffer and file unchanged"))
      (with-current-buffer buffer (save-buffer)))
    (let* ((inventory (skills-chooser--inventory library))
           (previous
            (when (file-exists-p list-file)
              (skills-chooser--read-disk-configuration list-file)))
           (old-items (and previous (skills-chooser--configuration-items previous)))
           (old-names (mapcar (lambda (item) (plist-get item :name)) old-items))
           (new-names (mapcar (lambda (item) (plist-get item :name)) inventory))
           (added (length (seq-difference new-names old-names)))
           (removed (length (seq-difference old-names new-names)))
           (retained (length (seq-intersection new-names old-names)))
           (document (skills-chooser--document library inventory previous)))
      (skills-chooser--atomic-write
       list-file (org-element-interpret-data document))
      (skills-chooser--refresh-visiting-buffer list-file)
      (message "Skills Chooser: updated %s (%d added, %d removed, %d retained)"
               list-file added removed retained)
      list-file)))

;;;###autoload
(defun skills-chooser-apply (&optional root)
  "Synchronize selected skills for workspace ROOT.
Use unsaved contents when the list file has a visiting buffer.  Empty and
intermediate checkboxes mean link or unselected; only checked boxes mean copy
or selected.  Installation stops during preflight on any source or conflict
error, leaving unmanaged files untouched."
  (interactive)
  (let* ((workspace (skills-chooser--workspace-root root))
         (library (skills-chooser--library-directory (called-interactively-p 'interactive)))
         (list-file (skills-chooser--list-file workspace))
         (target (skills-chooser--target-directory workspace)))
    (skills-chooser--display-context workspace library)
    (let* ((source-info (skills-chooser--read-configuration list-file))
           (configuration (plist-get source-info :configuration))
           (inventory (skills-chooser--inventory library))
           (manifest
            (skills-chooser--read-manifest
             (expand-file-name skills-chooser--manifest-name target)))
           (plan (skills-chooser--plan configuration inventory manifest target))
           (counts (skills-chooser--execute-plan plan target))
           (entries
            (mapcar
             (lambda (skill)
               (list :id (plist-get skill :name)
                     :destination (plist-get skill :destination)
                     :source (plist-get skill :source-directory)
                     :method (plist-get skill :method)))
             (plist-get plan :desired)))
           (manifest-text (skills-chooser--manifest-text entries)))
      (skills-chooser--atomic-write
       (expand-file-name skills-chooser--manifest-name target) manifest-text t)
      (message
       "Skills Chooser: %d linked, %d copied, %d refreshed, %d removed, %d unchanged, %d skipped unmanaged%s"
       (plist-get counts :linked) (plist-get counts :copied)
       (plist-get counts :refreshed) (plist-get counts :removed)
       (plist-get counts :unchanged)
       (skills-chooser--unmanaged-count target entries)
       (if (plist-get source-info :unsaved)
           "; applied unsaved buffer contents"
         ""))
      (expand-file-name skills-chooser--manifest-name target))))

(provide 'skills-chooser)
;;; skills-chooser.el ends here
