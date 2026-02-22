;;; vui-stub.el --- Minimal vui stubs for unit tests  -*- lexical-binding: t; -*-

;; This file provides only what is needed to load `eijiro-search.el` in tests.

(defmacro vui-defcomponent (&rest _body)
  "Stub for `vui-defcomponent`."
  nil)

(defmacro vui-use-effect (&rest _body)
  "Stub for `vui-use-effect`."
  nil)

(defun vui-set-state (&rest _args)
  "Stub for `vui-set-state`."
  nil)

(defun vui-text (&rest args)
  "Stub for `vui-text`."
  args)

(defun vui-table (&rest args)
  "Stub for `vui-table`."
  args)

(defun vui-vstack (&rest args)
  "Stub for `vui-vstack`."
  args)

(defun vui-hstack (&rest args)
  "Stub for `vui-hstack`."
  args)

(defun vui-field (&rest args)
  "Stub for `vui-field`."
  args)

(defun vui-select (&rest args)
  "Stub for `vui-select`."
  args)

(defun vui-checkbox (&rest args)
  "Stub for `vui-checkbox`."
  args)

(defun vui-component (&rest args)
  "Stub for `vui-component`."
  args)

(defun vui-mount (&rest _args)
  "Stub for `vui-mount`."
  nil)

(provide 'vui-stub)
(provide 'vui)
;;; vui-stub.el ends here
