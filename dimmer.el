;;; dimmer.el --- visually highlight the selected buffer

;; Copyright (C) 2017-2018 Neil Okamoto

;; Filename: dimmer.el
;; Author: Neil Okamoto
;; Version: 0.3.0-SNAPSHOT
;; Package-Requires: ((emacs "25"))
;; URL: https://github.com/gonewest818/dimmer.el
;; Keywords: faces, editing
;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 
;;; Commentary:
;; 
;; This module provides a subtle visual indication which window is
;; currently active by dimming the faces on the others.  It does this
;; nondestructively, and computes the dimmed faces dynamically such
;; that your overall color scheme is shown in a muted form without
;; requiring you to define the "dim" versions of every face.
;; 
;; The *percentage* of dimming is user configurable.
;; 
;; The *direction* of dimming is computed on the fly.  For instance,
;; if you have a dark theme then the dimmed face is darker, and if you
;; have a light theme the dimmed face is lighter.
;; 
;; Caveats:
;; 
;; This module makes use of the `face-remap-*` APIs in Emacs and these
;; APIs work on buffers rather than windows.  This means anytime you
;; have multiple windows displaying the same buffer they will dim or
;; undim together.  In my configuration I combine this package with
;; `global-hl-line-mode` so that it's also clear which window is
;; active.
;; 
;; Users of light themes may need to increase `dimmer-fraction` in
;; order to see the effect.
;; 
;; Usage:
;; 
;;      (require 'dimmer) ; unless installed as a package
;;      (dimmer-mode)
;; 
;; Customization:
;; 
;; `dimmer-fraction` controls the degree to which unselected buffers
;; are dimmed.  Range is 0.0 - 1.0, and default is 0.20.  Increase
;; value if you like the other buffers to be more dim.
;; 
;; Use `dimmer-exclusion-regexp` to describe patterns for buffer names
;; that should never be dimmed, for example, you could match buffers
;; created by helm.
;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;; 
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;; 
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.
;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 
;;; Code:

(require 'cl-lib)
(require 'color)
(require 'face-remap)
(require 'seq)
(require 'subr-x)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; configuration

(defgroup dimmer nil
  "Highlight current-buffer by dimming faces on the others."
  :prefix "dimmer-"
  :group 'convenience
  :link '(url-link :tag "GitHub" "https://github.com/gonewest818/dimmer.el"))

(defcustom dimmer-fraction 0.20
  "Control the degree to which buffers are dimmed (0.0 - 1.0)."
  :type '(float)
  :group 'dimmer)
(define-obsolete-variable-alias 'dimmer-percent 'dimmer-fraction)

(defcustom dimmer-exclusion-regexp nil
  "Regular expression describing buffer names that are never dimmed."
  :type '(regexp)
  :group 'dimmer)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; implementation

(defvar-local dimmer-buffer-face-remaps nil
  "Per-buffer face remappings needed for later clean up.")

(defconst dimmer-dimmed-faces (make-hash-table :test 'equal)
  "Cache of face names with their computed dimmed values.")

(defconst dimmer-last-buffer nil
  "Identity of the last buffer to be made current.")

(defconst dimmer-debug-messages nil
  "Enable debugging output to *Messages* buffer.")

(defun dimmer-lerp (frac v0 v1)
  "Use FRAC to compute a linear interpolation of V0 and V1."
  (+ (* v0 (- 1.0 frac))
     (* v1 frac)))

(defun dimmer-compute-rgb-in-RGB-space (fg bg frac)
  "Compute \"dimming\" by linear interpolation in RGB space.
Blends the foreground FG and the background BG using FRAC to
control the interpolation.

When FRAC is 0.0, the result is equal to FG.
When FRAC is 1.0, the result is equal to BG.

Any other value for FRAC means the result's hue, saturation, and
value will be adjusted linearly so that the color sits somewhere
between FG and BG.

Mathematically: the resulting color C sits on the line segment
connecting the colors FG and BG such that the Euclidian distance
between FG and C is FRAC times the distance between FG and BG."
  (apply 'color-rgb-to-hex
         (cl-mapcar (apply-partially 'dimmer-lerp frac) fg bg)))

(defun dimmer-compute-rgb-in-HSL-space (fg bg frac)
  "Compute \"dimming\" by linear interpolation in HSL space.
Blends the foreground FG and the background BG using FRAC to
control the interpolation.

When FRAC is 0.0, the result is equal to FG.
When FRAC is 1.0, the result is equal to BG.

Any other value for FRAC means the result's hue, saturation, and
value will be adjusted linearly so that the color sits somewhere
between FG and BG.

Mathematically: the resulting color C sits on the line segment
connecting the colors FG and BG such that the Euclidian distance
between FG and C is FRAC times the distance between FG and BG."
  (apply 'color-rgb-to-hex
         (apply 'color-hsl-to-rgb
                (cl-mapcar (apply-partially 'dimmer-lerp frac)
                           (apply 'color-rgb-to-hsl fg)
                           (apply 'color-rgb-to-hsl bg)))))

(defun dimmer-compute-rgb-in-LAB-space (fg bg frac)
  "Compute \"dimming\" by linear interpolation in CIELAB space.
Blends the foreground FG and the background BG using FRAC to
control the interpolation.

When FRAC is 0.0, the result is equal to FG.
When FRAC is 1.0, the result is equal to BG.

Any other value for FRAC means the result's hue, saturation, and
value will be adjusted linearly so that the color sits somewhere
between FG and BG.

Mathematically: the resulting color C sits on the line segment
connecting the colors FG and BG such that the Euclidian distance
between FG and C is FRAC times the distance between FG and BG. We
perform this transformation in the CIELAB 1976 color space. In
practice, operations in CIELAB space can lead to colors outside
the range 0-255; therefore we must clamp the channel values as we
convert back to RGB."
  (apply 'color-rgb-to-hex
         (mapcar 'color-clamp
                 (apply 'color-lab-to-srgb
                        (cl-mapcar (apply-partially 'dimmer-lerp frac)
                                   (apply 'color-srgb-to-lab fg)
                                   (apply 'color-srgb-to-lab bg))))))

(defalias 'dimmer-compute-rgb 'dimmer-compute-rgb-in-LAB-space)

(defun dimmer-face-color (f frac)
  "Compute a dimmed version of the foreground color of face F.
FRAC is the amount of dimming where 0.0 is no change and 1.0 is
maximum change."
  (let ((fg (face-foreground f))
        (bg (face-background 'default)))
    (when (and fg (color-defined-p fg)
               bg (color-defined-p bg))
      (let ((key (format "%s-%s-%f" fg bg frac)))
        (or (gethash key dimmer-dimmed-faces)
            (let ((rgb (dimmer-compute-rgb (color-name-to-rgb fg)
                                           (color-name-to-rgb bg)
                                           frac)))
              (when rgb
                (puthash key rgb dimmer-dimmed-faces)
                rgb)))))))

(defun dimmer-dim-buffer (buf frac)
  "Dim all the faces defined in the buffer BUF.
FRAC controls the dimming as defined in ‘dimmer-face-color’."
  (with-current-buffer buf
    (unless dimmer-buffer-face-remaps
      (dolist (f (face-list))
        (let ((c (dimmer-face-color f frac)))
          (when c  ; e.g. "(when-let* ((c (...)))" in Emacs 26
            (push (face-remap-add-relative f :foreground c)
                  dimmer-buffer-face-remaps)))))))

(defun dimmer-restore-buffer (buf)
  "Restore the un-dimmed faces in the buffer BUF."
  (with-current-buffer buf
    (when dimmer-buffer-face-remaps
      (mapc 'face-remap-remove-relative dimmer-buffer-face-remaps)
      (setq dimmer-buffer-face-remaps nil))))

(defun dimmer-filtered-buffer-list ()
  "Get filtered subset of all visible buffers in all frames."
  (let (buffers)
    (walk-windows
     (lambda (win)
       (let* ((buf (window-buffer win))
              (name (buffer-name buf)))
         (unless (and dimmer-exclusion-regexp
                      (string-match-p dimmer-exclusion-regexp name))
           (push buf buffers))))
     nil
     t)
    buffers))

(defun dimmer-process-all ()
  "Process all buffers and dim or un-dim each."
  (let ((selected (current-buffer)))
    (setq dimmer-last-buffer selected)
    (dolist (buf (dimmer-filtered-buffer-list))
      (if (eq buf selected)
          (dimmer-restore-buffer buf)
        (dimmer-dim-buffer buf dimmer-fraction)))))

(defun dimmer-dim-all ()
  "Dim all buffers."
  (dimmer--dbg "dimmer-dim-all")
  (mapc (lambda (buf)
          (dimmer-dim-buffer buf dimmer-fraction))
        (buffer-list)))

(defun dimmer-restore-all ()
  "Un-dim all buffers."
  (mapc 'dimmer-restore-buffer (buffer-list)))

(defun dimmer-command-hook ()
  "Process all buffers if current buffer has changed."
  (dimmer--dbg "dimmer-command-hook")
  (unless (eq (window-buffer) dimmer-last-buffer)
    (dimmer-process-all)))

(defun dimmer-config-change-hook ()
  "Process all buffers if window configuration has changed."
  (dimmer--dbg "dimmer-config-change-hook")
  (dimmer-process-all))

;;;###autoload
(define-minor-mode dimmer-mode
  "visually highlight the selected buffer"
  nil
  :lighter ""
  :global t
  :require 'dimmer
  (if dimmer-mode
      (progn
        (add-hook 'focus-in-hook 'dimmer-config-change-hook)
        (add-hook 'focus-out-hook 'dimmer-dim-all)
        (add-hook 'post-command-hook 'dimmer-command-hook)
        (add-hook 'window-configuration-change-hook 'dimmer-config-change-hook))
    (remove-hook 'focus-in-hook 'dimmer-config-change-hook)
    (remove-hook 'focus-out-hook 'dimmer-dim-all)
    (remove-hook 'post-command-hook 'dimmer-command-hook)
    (remove-hook 'window-configuration-change-hook 'dimmer-config-change-hook)
    (dimmer-restore-all)))

;;;###autoload
(define-obsolete-function-alias 'dimmer-activate 'dimmer-mode)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; debugging - call from *scratch*, ielm, or eshell

(defun dimmer--debug-face-remapping-alist (name &optional clear)
  "Display 'face-remapping-alist' for buffer NAME (or clear if CLEAR)."
  (with-current-buffer name
    (if clear
        (setq face-remapping-alist nil)
      face-remapping-alist)))

(defun dimmer--debug-buffer-face-remaps (name &optional clear)
  "Display 'dimmer-buffer-face-remaps' for buffer NAME (or clear if CLEAR)."
  (with-current-buffer name
    (if clear
        (setq dimmer-buffer-face-remaps nil)
      dimmer-buffer-face-remaps)))

(defun dimmer--debug-reset (name)
  "Clear 'face-remapping-alist' and 'dimmer-buffer-face-remaps' for NAME."
  (dimmer--debug-face-remapping-alist name t)
  (dimmer--debug-buffer-face-remaps name t)
  (redraw-display))

(defun dimmer--dbg (label)
  "Print a debug state with the given LABEL."
  (if dimmer-debug-messages
      (let ((inhibit-message t))
        (message "%s: cb '%s' wb '%s' last '%s' %s"
                 label
                 (current-buffer)
                 (window-buffer)
                 dimmer-last-buffer
                 (if (not (eq (current-buffer) (window-buffer)))
                     "**"
                   "")))))

(provide 'dimmer)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; dimmer.el ends here
