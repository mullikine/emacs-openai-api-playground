(require 'pen-openai)

(defset pen-completion-backends
  ;; name completion command and a list of engines
  `(("OpenAI GPT-3" "openai-complete.sh" ,(pen-openai-list-engines))
    ("EleutherAI GPT-J" "gpt-j-complete.sh" ("2.7B" "1.3B"))
    ("EleutherAI GPT-Neo" "gpt-neo-complete.sh" ("2.7B" "1.3B"))
    ("EleutherAI GPT-NeoX" "gpt-neox-complete.sh" ("2.7B" "1.3B"))))

(defun pen-select-completion-backend ()
  (interactive)
  (let* ((options
          (mapcar 'pp-ol
                  (flatten-once
                   (loop for trip in pen-completion-backends collect
                         (pen-cartesian-product (list (car trip)) (list (nth 1 trip)) (nth 2 trip))))))
         (sel (fz
               options
               nil nil "pen completion backend: ")))
    (if sel
        (eval-string (concat "'" sel)))))

(provide 'pen-lm-completers)