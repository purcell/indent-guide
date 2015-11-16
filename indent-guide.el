;;; indent-guide.el --- show vertical lines to guide indentation

;; Copyright (C) 2013-2015 zk_phi

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA

;; Author: zk_phi
;; URL: http://hins11.yu-yake.com/
;; Version: 2.3.0-XPM

;;; Commentary:

;; Require this script
;;
;;   (require 'indent-guide)
;;
;; and call command "M-x indent-guide-mode".

;; If you want to enable indent-guide-mode automatically,
;; call "indent-guide-global-mode" function.
;;
;;   (indent-guide-global-mode)

;; Column lines are propertized with "indent-guide-color". So you may
;; configure this face to make guides more pretty in your colorscheme.
;;
;;   (setq indent-guide-color "dimgray")

;;; Change Log:

;; 1.0.0 first released
;; 1.0.1 cleaned and optimized code
;;       works better for the file without trailing-whitespaces
;; 1.0.2 modified behavior for lines with only whitespaces
;; 1.0.3 Allow custom indent guide char
;; 1.0.4 disabled in org-indent-mode
;; 1.0.5 faster update of indent-guide (especially for huge files)
;; 1.1.0 work with tab-indented files
;; 1.1.1 turned into minor-mode
;; 1.1.2 an infinite-loop bug fix
;; 1.1.3 changed behavior for blank lines
;; 2.0.0 rewrite almost everything
;; 2.0.1 improve blank-line and tab handling
;; 2.0.2 fixed bug that sometimes newline gets invisible
;; 2.0.3 added indent-guide-global-mode
;; 2.1.0 now lines are not drawn over the cursor
;; 2.1.1 work better with blank lines
;; 2.1.2 fixed bug in empty files
;; 2.1.3 better bob and eob handling
;; 2.1.4 use "display" property instead of "before-string"
;;       (now works better with hl-line and linum)
;; 2.1.5 add "indent-guide-inhibit-modes"
;; 2.1.6 add option "indent-guide-recursive"
;; 2.2.0 add option "indent-guide-threshold"
;; 2.3.0 use regexp search to find the beginning of level
;; 2.3.0-XPM removed troublesome options and add XPM support

;;; Code:

(require 'cl-lib)

(defconst indent-guide-version "2.3.0-XPM")

;; * customs

(defgroup indent-guide nil
  "Show vertical lines to guide indentation."
  :group 'emacs)

(defcustom indent-guide-inhibit-modes
  '(tabulated-list-mode
    special-mode
    dired-mode
    eww-mode
    eshell-mode)
  "List of major-modes in which indent-guide should be turned off."
  :type '(repeat symbol)
  :group 'indent-guide)

(defcustom indent-guide-delay nil
  "When a positive number, rendering guide lines is delayed DELAY
  seconds."
  :type 'number
  :group 'indent-guide)

(defcustom indent-guide-threshold -1
  "Guide lines are drawn only when the column number is over this
  value."
  :type 'number
  :group 'indent-guide)

(defcustom indent-guide-color "#535353"
  "Color used for indent guide lines."
  :type 'string
  :group 'indent-guide)

(defcustom indent-guide-char-width 'dynamic
  "Width in pixels of a character. This variable can be either a
natural number or `dynamic' and used to render guide lines."
  :group 'indent-guide)

(defcustom indent-guide-char-height 'dynamic
  "Height in pixels of a character. This variable can be either a
natural number or `dynamic' and used to render guide lines."
  :group 'indent-guide)

(defcustom indent-guide-line-char ?|
  "Char used to render guide lines when XPM images are not
available."
  :group 'indent-guide)

(defcustom indent-guide-line-enable-xpm t
  "When non-nil, XPM images are used to render guide lines."
  :group 'indent-guide)

(defcustom indent-guide-line-left-margin (/ (frame-char-width) 2)
  "Left margin of the guide lines."
  :type 'number
  :group 'indent-guide)

(defcustom indent-guide-line-height-adjustment 0
  "Height in pixels added to `frame-line-height'. The value can
also be negative. This adjustment may be useful on some
platforms, on which increases the line height when an image whose
height is 100% of the line hight is rendered in the line."
  :type 'number
  :group 'indent-guide)

(defcustom indent-guide-line-dash-length nil
  "Dash length of the guide lines, or `nil' for solid lines."
  :type 'number
  :group 'indent-guide)

;; * variables

(defvar indent-guide--timer-object nil)

;; * utilities

(defun indent-guide--active-overlays ()
  "Return the list of all overlays created by indent-guide."
  (delq nil
        (mapcar
         (lambda (ov)
           (and (eq (overlay-get ov 'category) 'indent-guide) ov))
         (overlays-in (point-min) (point-max)))))

(defun indent-guide--indentation-candidates (level)
  "*Internal function for `indent-guide--beginning-of-level'."
  (cond ((<= level 0)
         (list ""))
        ((>= level tab-width)
         (cons (concat "\t" (make-string (- level tab-width) ?\s))
               (cons (make-string level ?\s)
                     (indent-guide--indentation-candidates (1- level)))))
        (t
         (cons (make-string level ?\s)
               (indent-guide--indentation-candidates (1- level))))))

(defun indent-guide--beginning-of-level ()
  "Move to the beginning of current indentation level and return
the point."
  (back-to-indentation)
  (let* ((base-level (if (not (eolp))
                         (current-column)
                       (max (save-excursion
                              (skip-chars-forward "\s\t\n")
                              (back-to-indentation)
                              (current-column))
                            (save-excursion
                              (skip-chars-backward "\s\t\n")
                              (back-to-indentation)
                              (current-column)))))
         (candidates (indent-guide--indentation-candidates (1- base-level)))
         (regex (concat "^" (regexp-opt candidates t) "[^\s\t\n]")))
    (if (zerop base-level)
        (point)
      (beginning-of-line)
      (or (and (search-backward-regexp regex nil t)
               (goto-char (match-end 1)))
          (goto-char (point-min))))))

(defun indent-guide--get-char-width ()
  (let* ((p1 (pos-visible-in-window-p (point) nil t))
         (p2 (and (not (eolp))
                  (pos-visible-in-window-p (1+ (point)) nil t))))
    (if (and p1 p2) (- (car p2) (car p1)) (frame-char-width))))

(defun indent-guide--get-char-height ()
  (let* ((p1 (pos-visible-in-window-p (point) nil t))
         (p2 (save-excursion
               (and (zerop (forward-line 1))
                    (pos-visible-in-window-p (point) nil t)))))
    (if (and p1 p2) (- (cadr p2) (cadr p1)) (frame-char-height))))

(defvar indent-guide--image-cache nil)
(defun indent-guide--make-image (length position char-width char-height &optional stringp)
  "Make a string for overlays."
  (let* ((width (* length char-width))
         (height (+ char-height indent-guide-line-height-adjustment))
         (cached (assoc (list width height position) indent-guide--image-cache)))
    (unless cached
      (let* ((posn (+ (* position char-width) indent-guide-line-left-margin))
             (img (create-image
                   (with-temp-buffer
                     (insert "/* XPM */ static char * x[] = {"
                             (format "\"%d %d 2 1\"" width height)
                             (format ",\". c %s\"" indent-guide-color)
                             ",\"  c None\"")
                     (dotimes (i height)
                       (insert (if (and indent-guide-line-dash-length
                                        (zerop (mod (1+ i) (1+ indent-guide-line-dash-length))))
                                   (concat ",\"" (make-string width ?\s) "\"")
                                 (concat ",\"" (make-string posn ?\s) "."
                                         (make-string (- width posn 1) ?\s) "\""))))
                     (insert "}")
                     (buffer-string))
                   'xpm t :ascent 'center))
             (str (let ((s (make-string length ?\s)))
                    (aset s position indent-guide-line-char)
                    (propertize s 'face `(:foreground ,indent-guide-color)))))
        (push (setq cached (cons (list width height position) (cons str img)))
              indent-guide--image-cache)))
    (let ((img (cdr (cdr cached))) (str (car (cdr cached))))
      (cond ((or (not indent-guide-line-enable-xpm)
                 (not window-system))
             str)
            (stringp
             (propertize str 'display img))
            (t
             img)))))

;; * generate guides

(defun indent-guide--make-overlay (line col)
  "draw line at (line, col)"
  (save-excursion
    ;; try to goto (line, col)
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column col)
    (let ((char-width (if (eq indent-guide-char-width 'dynamic)
                          (indent-guide--get-char-width)
                        indent-guide-char-width))
          (char-height (if (eq indent-guide-char-height 'dynamic)
                           (indent-guide--get-char-height)
                         indent-guide-char-height))
          size diff string ov prop)
      ;; calculate difference from the actual col
      (setq diff (- col (current-column)))
      ;; make overlay or not
      (cond ((and (eolp) (<= 0 diff))   ; the line is too short
             ;; <-line-width->  <-diff->
             ;;               []        |
             (setq string (indent-guide--make-image (1+ diff) diff char-width char-height t)
                   prop   'before-string
                   ov     (make-overlay (point) (point))))
            ((< diff 0)                 ; the column is inside a tab
             ;;  <---tab-width-->
             ;;      <-(- diff)->
             ;;     |            []
             (setq string (indent-guide--make-image tab-width (- diff) char-width char-height)
                   prop   'display
                   ov     (make-overlay (point) (1- (point)))))
            ((looking-at "\t")          ; okay but looking at tab
             ;;    <-tab-width->
             ;; [|]
             (setq string (indent-guide--make-image tab-width 0 char-width char-height)
                   prop   'display
                   ov     (make-overlay (point) (1+ (point)))))
            (t                          ; okay and looking at a space
             (setq string (indent-guide--make-image 1 0 char-width char-height)
                   prop   'display
                   ov     (make-overlay (point) (1+ (point))))))
      (when ov
        (overlay-put ov 'category 'indent-guide)
        (overlay-put ov prop string)))))

(defun indent-guide-show ()
  (interactive)
  (unless (or (indent-guide--active-overlays)
              (active-minibuffer-window))
    (let ((win-start (window-start))
          (win-end (window-end nil t))
          line-col line-start line-end
          last-col)
      ;; decide line-col, line-start
      (save-excursion
        (indent-guide--beginning-of-level)
        (setq line-col (current-column)
              line-start (max (1+ (line-number-at-pos))
                              (line-number-at-pos win-start))))
      (when (> line-col indent-guide-threshold)
        ;; decide line-end
        (save-excursion
          (while (and (progn (back-to-indentation)
                             (or (< line-col (current-column)) (eolp)))
                      (forward-line 1)
                      (not (eobp))
                      (<= (point) win-end)))
          (when (>= line-col (setq last-col (current-column)))
            (forward-line -1)
            (while (and (looking-at "[\s\t\n]*$")
                        (> (point) line-start)
                        (zerop (forward-line -1)))))
          (setq line-end (line-number-at-pos)))
        ;; draw line
        (dotimes (tmp (- (1+ line-end) line-start))
          (indent-guide--make-overlay (+ line-start tmp) line-col))
        (remove-overlays (point) (point) 'category 'indent-guide)))))

(defun indent-guide-remove ()
  (dolist (ov (indent-guide--active-overlays))
    (delete-overlay ov)))

;; * minor-mode

(defun indent-guide-post-command-hook ()
  (if (null indent-guide-delay)
      (indent-guide-show)
    (when (null indent-guide--timer-object)
      (setq indent-guide--timer-object
            (run-with-idle-timer indent-guide-delay nil
                                 (lambda ()
                                   (indent-guide-show)
                                   (setq indent-guide--timer-object nil)))))))

(defun indent-guide-pre-command-hook ()
  (indent-guide-remove))

;;;###autoload
(define-minor-mode indent-guide-mode
  "show vertical lines to guide indentation"
  :init-value nil
  :lighter " ing"
  :global nil
  (if indent-guide-mode
      (progn
        (add-hook 'pre-command-hook 'indent-guide-pre-command-hook nil t)
        (add-hook 'post-command-hook 'indent-guide-post-command-hook nil t))
    (remove-hook 'pre-command-hook 'indent-guide-pre-command-hook t)
    (remove-hook 'post-command-hook 'indent-guide-post-command-hook t)))

;;;###autoload
(define-globalized-minor-mode indent-guide-global-mode
  indent-guide-mode
  (lambda ()
    (unless (cl-some 'derived-mode-p indent-guide-inhibit-modes)
      (indent-guide-mode 1))))

;; * provide

(provide 'indent-guide)

;;; indent-guide.el ends here
