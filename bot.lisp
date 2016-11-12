;; (progn
;;   (ql:quickload 'cl-irc)
;;   (ql:quickload 'drakma)
;;   (ql:quickload 'cl-json)
;;   (ql:quickload 'flexi-streams))

(progn
  (load "./bundle/bundle.lisp")
  (cl:require :cl-irc)
  (cl:require :drakma)
  (cl:require :cl-json)
  (cl:require :flexi-streams))

(defpackage :midymidybot
  (:use :cl :cl-user :cl-irc :irc :drakma :json)
  (:export :bot-start
           :bot-halt))

(in-package :midymidybot)
(defvar *log-out* *standard-output*)
(load "./utils.lisp")

(defstruct bot
  (irc-name nil :type string)
  (irc-passwd nil :type string)
  (irc-channel nil :type string)
  irc-connection
  (irc-ping-semaphore (sb-thread:make-semaphore)
                      :type sb-thread:semaphore)
  (irc-message-pool-head nil :type cons)
  (irc-message-pool-tail nil :type cons)
  (irc-message-pool-lock
   (sb-thread:make-mutex)
   :type sb-thread:mutex)
  (irc-reconnect-counter 0 :type integer)

  (tg-bot-id nil :type integer)
  (tg-bot-authstr nil :type string)
  (tg-chat-id nil :type integer)

  (thread-irc-read-loop nil :type sb-thread:thread)
  (thread-irc-watcher nil :type sb-thread:thread)
  (thread-tg-loop nil :type sb-thread:thread))

;; (defparameter *irc-channel* "#MidyMidymc")

;; (defparameter *tg-auth-str*
;;   (with-open-file (stream "./account_tg")
;;     (read-line stream)))

;; (defparameter *tg-chat-id* -1001067573593)
;; (defparameter *tg-bot-id* 258812230)

;; (defparameter *irc-connection* nil)
;; (defvar *ping-semaphore* (sb-thread:make-semaphore))
;; (defparameter *irc-read-loop* nil)
;; (defvar *tg-message-sender*)

(defun msg-user (msg)
  (source msg))

(defun is-privmsg? (msg)
  (string= "PRIVMSG" (command msg)))

(defun msg-channel (msg)
  (car (arguments msg)))

(defun msg-body (msg)
  (cadr (arguments msg)))

(defun msgstr-irc->tg (msg)
  (concatenate 'string (msg-user msg) ": " (msg-body msg)))

(defun send-irc-message (bot str)
  (privmsg (bot-irc-connection bot)
           (bot-irc-channel bot)
           (correct-cljson-surrogate-pairs str)))

(defun init-bot-irc-msg-pool (bot)
  (setf (bot-irc-message-pool-head bot) (list :head))
  (setf (bot-irc-message-pool-tail bot)
        (bot-irc-message-pool-head bot))
  (setf (bot-irc-message-pool-lock bot)
        (sb-thread:make-mutex
         :name "bot-irc-message-pool-lock")))

(defun push-msg-pool (str bot)
  (sb-thread:with-mutex ((bot-irc-message-pool-lock bot))
    (let ((new (list str)))
      (setf (cdr (bot-irc-message-pool-tail bot)) new)
      (setf (bot-irc-message-pool-tail bot) new))))

(defun clear-msg-pool-f (bot)
  (sb-thread:with-mutex ((bot-irc-message-pool-lock bot))
    (if (cdr (bot-irc-message-pool-head bot))
        (handler-case
            (progn
              (send-irc-message
               bot
               (cadr (bot-irc-message-pool-head bot)))
              (setf (cdr (bot-irc-message-pool-head bot))
                    (cddr (bot-irc-message-pool-head bot)))
              (clear-msg-pool-f bot))
          (condition ()
            (logging "clear-msg-pool-f: Can NOT send irc msg, give up!")))
        ;; finish, reset tail
        (setf (bot-irc-message-pool-tail bot)
              (bot-irc-message-pool-head bot)))))

;; supress warning
(defun bot-halt (bot) bot)
(defun send-tg-message (bot str) bot str)
(defun irc-check-connection (bot) bot)
(defun irc-reconnect (bot &optional (callback nil))
  (tryto (remove-all-hooks (bot-irc-connection bot)))
  (tryto (quit (bot-irc-connection bot)))
  (tryto (sb-thread:terminate-thread
          (bot-thread-irc-read-loop bot)))
  (sleep 5)
  (logging "Connecting to IRC")
  (setf (bot-irc-connection bot)
        (connect :nickname (bot-irc-name bot)
                 :server "irc.freenode.net"))
  (logging "JOIN CHANNEL")
  (join (bot-irc-connection bot) (bot-irc-channel bot))
  (logging "ADD HOOKS")
  (add-hook (bot-irc-connection bot)
            'irc::irc-privmsg-message
            (lambda (msg)
              (if (string= (bot-irc-channel bot)
                           (msg-channel msg))
                  (send-tg-message bot
                                   (msgstr-irc->tg msg)))))
  (add-hook (bot-irc-connection bot)
            'irc::irc-pong-message
            (lambda (msg)
              (declare (ignore msg))
              (sb-thread:signal-semaphore
               (bot-irc-ping-semaphore bot))))
  (logging "ACTIVATE IRC-READ-LOOP")
  (setf (bot-thread-irc-read-loop bot)
        (sb-thread:make-thread
         (lambda ()
           (read-message-loop (bot-irc-connection bot)))
         :name "IRC-READ-LOOP"))
  (if callback
      (funcall callback)))

(defun irc-shutdown (bot)
  (part (bot-irc-connection bot)
        (bot-irc-channel bot) "Bot shutdown")
  (quit (bot-irc-connection bot) "leaving"))

(defun irc-check-connection (bot)
  (let ((t1 (get-internal-real-time)))
    (tryto (ping (bot-irc-connection bot) (bot-irc-channel bot)))
    (if (sb-thread:wait-on-semaphore
         (bot-irc-ping-semaphore bot) :timeout 20)
        (let ((time-elapse
               (float (/ (- (get-internal-real-time) t1)
                         internal-time-units-per-second))))
          (setf (bot-irc-ping-semaphore bot)
                (sb-thread:make-semaphore))
          time-elapse)
        (progn (setf (bot-irc-ping-semaphore bot)
                     (sb-thread:make-semaphore))
               nil))))

;;;; -----------------------------------------

(defun tg-request (bot method-name &optional parameters)
  (let ((http-method (if parameters :post :get)))
    (flexi-streams:octets-to-string
     (http-request
      (concatenate 'string
                   "https://api.telegram.org/"
                   (bot-tg-bot-authstr bot) "/"
                   method-name)
      :connection-timeout 100
      :method http-method
      :content-type "application/json"
      :content (if parameters
                   (with-output-to-string (stream)
                     (encode-json parameters stream))))
     :external-format '(:utf-8 :eol-style :crlf))))

(defun decoded-tg-request (bot method-name &optional parameters)
  (with-input-from-string
      (stream (tg-request bot method-name parameters))
    (decode-json stream)))

(defun jget (tag decoded-json)
  (dolist (i decoded-json nil)
    (if (eq (car i) tag)
        (return (cdr i)))))

(defun tg-is-message? (update)
  (if (jget :message update) t nil))

(defun tg-is-text? (update)
  (if (jget :text (jget :message update)) t nil))

(defun tg-is-sticker? (update)
  (if (jget :sticker (jget :message update)) t nil))

(defun tg-is-reply? (update)
  (if (jget :reply--to--message
            (jget :message update)) t nil))

(defun tg-is-our-chat? (bot update)
  (= (bot-tg-chat-id bot)
     (jget :id (jget :chat (jget :message update)))))

(defun tg-is-photo? (update)
  (if (jget :photo
            (jget :message update)) t nil))

(defun tg-is-imageasfile? (update)
  (let ((doc (jget :document (jget :message update))))
    (if doc
        (string-begin-with
         "image"
         (jget :mime--type doc)))))

(defun tg-get-photo-id (update)
  (let ((file-lst (jget :photo
                        (jget :message update))))
    (setf file-lst ;; must less than 400KB
          (remove-if (lambda (file)
                       (> (jget :file--size file)
                          (* 400 1024)))
                     file-lst))
    (if (null file-lst)
        (error "ERROR: tg-get-photo-id: no suitable sized file"))
    (jget :file--id
          (car
           (sort file-lst
                 (lambda (a b)
                   (> (jget :file--size a)
                      (jget :file--size b))))))))

(defun tg-get-file-path (bot file-id)
  (jget :file--path
        (jget :result
              (decoded-tg-request bot
                                  "getFile" `(("file_id" . ,file-id))))))
(defun tg-download-file (bot file-path)
  (http-request
   (concatenate 'string
                "https://api.telegram.org/file/"
                (bot-tg-bot-authstr bot) "/"
                file-path)))

(defun tg-sender-first-name (update)
  (jget :first--name
        (jget :from
              (jget :message update))))

(defun msgstr-tg->irc-list (update)
  (let ((text (jget :text (jget :message update)))
        (str (make-str))
        (lst nil))
    (loop for c across text do
         (if (not (equal #\Newline c))
             (with-output-to-string (out str)
               (write-char c out))
             (progn (push str lst)
                    (setf str (make-str)))))
    (push str lst)
    (reverse lst)))

(defun remove-newline (str)
  (with-output-to-string (out)
    (loop for c across str do
         (write-char (if (equal #\Newline c)
                         #\Space c)
                     out))))

(defun tg-update-repliee-id (update)
  (jget :id
        (jget :from
              (jget :reply--to--message
                    (jget :message update)))))

(defun tg-update-repliee-first-name (update)
  (jget :first--name
        (jget :from
              (jget :reply--to--message
                    (jget :message update)))))

(defun msgstr-tgsticker->irc (update)
  (let ((emoji
         (jget :emoji
               (jget :sticker
                     (jget :message update)))))
    (concatenate 'string
                 emoji emoji emoji)))

(defun msgstr-tgphoto->irc (bot update)
  (let* ((img-vector
          (tg-download-file
           bot
           (tg-get-file-path
            bot
            (tg-get-photo-id update))))
         (url (with-input-from-string
                  (stream (upload-binary-file img-vector))
                (read-line stream)))
         (caption (jget :caption (jget :message update))))
    (concatenate 'string
                 "[ " url " ] " (if caption caption ""))))

(defun msgstr-tgimageasfile->irc (bot update)
  ;; check sieze
  (if (> (jget :file--size (jget :document
                                 (jget :message update)))
         (* 600 1024))
      "[ image > 600KB ]"
      (let* ((img-vector
              (tg-download-file
               bot
               (tg-get-file-path
                bot
                (jget :file--id
                      (jget :document
                            (jget :message update))))))
             (url
              (with-input-from-string
                  (stream (upload-binary-file img-vector))
                (read-line stream)))
             (caption (jget :caption (jget :message update))))
        (concatenate 'string
                     "[ " url " ] " (if caption caption)))))

(defun msgstr-tgreply->irc (bot update)
  "Transform only reply refer to irc, not text"
  (let* ((too-long     40)
         (dummy-update `(,(cons
                           :message
                           (jget
                            :reply--to--message
                            (jget :message update)))))
         (photo
          (if (tg-is-photo? dummy-update)
              "[ photo ]" nil))
         (file (if (jget :document
                         (jget :message dummy-update))
                   "[ file ]" nil))
         (sticker
          (if (tg-is-sticker? dummy-update)
              (msgstr-tgsticker->irc dummy-update)
              nil))
         (caption (jget :caption
                        (jget :message dummy-update)))
         (text (jget :text
                     (jget :message dummy-update)))
         (other-media (if (not (or photo file sticker text))
                          "[ other media ]"))
         (reply-to-text
          (remove-newline
           (with-output-to-string (out)
             (if photo (write-line photo out))
             (if file (write-line file out))
             (if caption (write-line caption out))
             (if sticker (write-line sticker out))
             (if other-media (write-line other-media out))
             (if text (write-string text out))
             out))))
    (if (= (tg-update-repliee-id update)
           (bot-tg-bot-id bot))
        (setf reply-to-text
              (concatenate 'string
                           "(IRC) "
                           reply-to-text))
        (setf reply-to-text
              (concatenate
               'string
               (tg-update-repliee-first-name update)
               ": " reply-to-text)))
    (let ((reply-to-text-cut
           (if (> (length reply-to-text) too-long)
               (concatenate 'string
                            (subseq reply-to-text
                                    0 too-long)
                            "......")
               reply-to-text)))
      (concatenate 'string
                   "[ Re: " reply-to-text-cut " ]"))))

(defun send-tg-message (bot str)
  (decoded-tg-request
   bot
   "sendMessage"
   `(("chat_id" . ,(bot-tg-chat-id bot))
     ("text" . ,str))))

(defun process-tg-msg (bot update)
  (if (tg-is-message? update) ; don't care about other data
      ;; one-line: reply, photo, file, sticker
      ;; multi-line: text
      (let* ((reply    (if (tg-is-reply? update)
                           (msgstr-tgreply->irc bot update)))
             (photo    nil) ;; deal with it later
             (file     nil) ;; deal with it later
             (sticker  (if (tg-is-sticker? update)
                           (msgstr-tgsticker->irc update)))
             (text-lst (if (tg-is-text? update)
                           (msgstr-tg->irc-list update)))
             (result   nil))
        (handler-case
            (progn
              (setf photo (if (tg-is-photo? update)
                              (msgstr-tgphoto->irc bot update)))
              (setf file (if (tg-is-imageasfile? update)
                             (msgstr-tgimageasfile->irc
                              bot update))))
          (condition (e)
            (logging
             "process-tg-msg: trouble on uploading file: ~A"
             e)))
        (setf result
              (append `(,reply ,photo ,file ,sticker)
                      text-lst))
        (if (not (or reply photo file sticker text-lst))
            (setf result `("[ other media ]")))
        (dolist (i result)
          (handler-case
              (if i (send-irc-message
                     bot
                     (concatenate 'string
                                  (tg-sender-first-name update)
                                  ": " i)))
            (condition (e)
              (progn
                (logging
                 "process-tg-msg: trouble of sending msg: ~A"
                 e))))))))

(defun tg-sort-result (result)
  (sort result
        (lambda (a b)
          (< (jget :update--id a)
             (jget :update--id b)))))

(defun tg-getupdate-loop (bot)
  "Need a `overheat' protection"
  (let ((offset 0))
    (loop
       (handler-case
           (let* ((response (decoded-tg-request
                             bot
                             "getUpdates"
                             `(("offset" . ,offset)
                               ("timeout" . 17))))
                  (result (tg-sort-result
                           (jget :result response))))
             (mapl (lambda (result-lst)
                     (if (null (cdr result-lst))
                         (setf offset
                               (1+ (jget :update--id
                                         (car result-lst)))))
                     (process-tg-msg bot (car result-lst)))
                   result))
         (condition (e)
           (progn (logging "TG-LOOP in trouble: ~S!" e)
                  ;; prevent loop overheat
                  (sleep 2)))))))

;;;;------------------------------------------------

(defun creat-watcher-f (bot)
  (logging "Create IRC watcher")
  (setf (bot-thread-irc-watcher bot)
        (sb-thread:make-thread
         (lambda ()
           (loop
              (sleep 60)
              (logging "Checking IRC Connection ...")
              (let ((delay (irc-check-connection bot)))
                (if delay
                    (progn
                      (logging "OK! Ping delay: ~As" delay)
                      (logging "Trying to clear Msg Pool")
                      (clear-msg-pool-f bot)
                      (setf (bot-irc-reconnect-counter bot) 0))
                    (progn
                      (logging "FAILED! RECONNECTING!")
                      (incf (bot-irc-reconnect-counter bot))
                      (if (> 20 (bot-irc-reconnect-counter bot))
                          (handler-case
                              (progn (irc-reconnect bot)
                                     (clear-msg-pool-f bot))
                            (condition (e)
                              (logging "Having Trouble: ~S" e)))
                          (progn (logging "Give up, Bot halt!")
                                 (bot-halt bot))))))))
         :name "IRC-WATCHER")))

(defun bot-load-conf (bot config)
  (let ((irc-conf (jget :irc config))
        (tg-conf (jget :tg config)))
    (setf (bot-irc-name bot) (jget :username irc-conf))
    (setf (bot-irc-channel bot) (jget :channel irc-conf))
    (setf (bot-tg-bot-id bot) (jget :bot-id tg-conf))
    (setf (bot-tg-bot-authstr bot) (jget :bot-token tg-conf))
    (setf (bot-tg-chat-id bot) (jget :chat-id tg-conf))
    (setf (bot-irc-reconnect-counter bot) 0)
    t))

(defun bot-start (config)
  (let ((bot (make-bot)))
    (bot-load-conf bot config)
    (init-bot-irc-msg-pool bot)
    (irc-reconnect bot)
    (logging "Creat TG LOOP")
    (setf (bot-thread-tg-loop bot)
          (sb-thread:make-thread (lambda ()
                                   (tg-getupdate-loop bot))
                                 :name "TG-LOOP"))
    (sleep 10)
    (creat-watcher-f bot)))

(defun bot-halt (bot)
  (tryto (irc-shutdown bot))
  (tryto (sb-thread:terminate-thread (bot-thread-irc-watcher bot)))
  (tryto (sb-thread:terminate-thread (bot-thread-irc-read-loop)))
  (tryto (sb-thread:terminate-thread (bot-thread-tg-loop bot))))
