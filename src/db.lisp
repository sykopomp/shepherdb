(in-package :shepherdb)

;;;
;;; Status codes
;;;
(defparameter *status-codes*
  '((200 . :ok)
    (201 . :created)
    (202 . :accepted)
    (404 . :not-found)
    (409 . :conflict)
    (412 . :precondition-failed)
    (500 . :internal-server-error)))

;;;
;;; Conditions
;;;
(define-condition couchdb-error () ())

(define-condition unexpected-response (couchdb-error)
  ((status-code :initarg :status-code :reader error-status-code)
   (response :initarg :response :reader error-response))
  (:report (lambda (condition stream)
             (format stream "Unexpected response with status code: ~A~@
                             HTTP Response: ~A"
                     (error-status-code condition)
                     (error-response condition)))))

;;;
;;; Database errors
;;;
(define-condition database-error (couchdb-error)
  ((uri :initarg :uri :reader database-error-uri)))

(define-condition db-not-found (database-error)
  ()
  (:report (lambda (condition stream)
             (format stream "Database ~A not found." (database-error-uri condition)))))

(define-condition db-already-exists (database-error)
  ()
  (:report (lambda (condition stream)
             (format stream "Database ~A already exists." (database-error-uri condition)))))

;;;
;;; Document errors
;;;
(define-condition document-error (couchdb-error) ())

(define-condition document-not-found (document-error)
  ((id :initarg :id :reader document-404-id)
   (db :initarg :db :reader document-404-db))
  (:report (lambda (e s)
             (format s "No document with id ~S was found in ~A"
                     (document-404-id e)
                     (document-404-db e)))))

(define-condition document-conflict (document-error)
  ((conflicting-doc :initarg :doc :reader conflicting-document)
   (conflicting-doc-id :initarg :id :reader conflicting-document-id))
  (:report (lambda (e s)
             (format s "Revision for ~A conflicts with latest revision for~@
                        document with ID ~S"
                     (conflicting-document e)
                     (conflicting-document-id e)))))

;;;
;;; Basic database API
;;;
(defparameter +utf-8+ (make-external-format :utf-8 :eol-style :lf))

(defproto =database= ()
  ((host "127.0.0.1")
   (port 5984)
   (name nil)
   (db-namestring nil))
  :documentation
  "Base database prototype. These objects represent the information required in order to communicate
with a particular CouchDB database.")
;; These extra replies handle automatic caching of the db-namestring used by db-request.
(defreply (setf host) :after (new-value (db =database=))
  (declare (ignore new-value))
  (setf (db-namestring db) (db->url db)))
(defreply (setf port) :after (new-value (db =database=))
  (declare (ignore new-value))
  (setf (db-namestring db) (db->url db)))
(defreply (setf name) :after (new-value (db =database=))
  (declare (ignore new-value))
  (setf (db-namestring db) (db->url db)))
(defreply db-namestring :around ((db =database=))
  (or (call-next-reply)
      (setf (db-namestring db) (db->url db))))

(defmessage db->url (db)
  (:documentation "Converts the connection information in DB into a URL string.")
  (:reply ((db =database=))
    (with-properties (host port name) db
      (format nil "http://~A:~A/~A" host port name))))

;; TODO - CouchDB places restrictions on what sort of URLs are accepted, such as everything having
;;        to be downcase, and only certain characters being accepted. There is also special meaning
;;        behing the use of /, so a mechanism to escape it in certain situations would be good.
(defmessage db-request (db &key)
  (:documentation "Sends a CouchDB request to DB.")
  ;; A note about this weirdness: The reason db-requests are so "unclean" is that
  ;; we use status codes for the various CouchDB requests to figure out if we got a
  ;; response we expected, and to detect errors. The downside of this approach is that
  ;; we must manually specify which HTTP response each reply that calls db-request accepts.
  ;;
  ;; There are, though, two big advantages to this approach:
  ;; 1. We do not need to deserialize JSON at all in order to figure out what happened.
  ;; 2. We get very descriptive errors with minimal overhead (not having to check a JSON object)
  ;;
  ;; Also as a result of this decision, the code in this file does not depend on a JSON library.
  ;; The user is free to handle serialization and deserialization themselves, and only when they need to.
  (:reply ((db =database=) &key (uri "") (method :get) content
           (external-format-out *drakma-default-external-format*)
           parameters additional-headers)
    (multiple-value-bind (response status-code)
        (http-request (format nil "~A/~A" (db-namestring db) uri) :method method :content content
                      :external-format-out external-format-out
                      :content-type "application/json"
                      :parameters parameters
                      :additional-headers additional-headers)
      (values response (or (cdr (assoc status-code *status-codes* :test #'=))
                           ;; The code should never get here once we know all the
                           ;; status codes CouchDB might return.
                           (error "Unknown status code: ~A. HTTP Response: ~A"
                                  status-code response))))))

(defmacro handle-request (result-var request &body expected-responses)
  (let ((status-code (gensym "STATUS-CODE-")))
    `(multiple-value-bind (,result-var ,status-code)
         ,request
       (case ,status-code
         ,@expected-responses
         (otherwise (error 'unexpected-response :status-code ,status-code :response ,result-var))))))

(defmessage db-info (db)
  (:documentation "Fetches info about a given database from the CouchDB server.")
  (:reply ((db =database=))
    (handle-request response (db-request db)
      (:ok response)
      (:internal-server-error (error "Illegal database name: ~A" (name db)))
      (:not-found (error 'db-not-found :uri (db-namestring db))))))

(defun connect-to-db (name &key (host "127.0.0.1") (port 5984) (prototype =database=))
  "Confirms that a particular CouchDB database exists. If so, returns a new database object
that can be used to perform operations on it."
  (let ((db (create prototype 'host host 'port port 'name name)))
    (when (db-info db)
      db)))

(defun create-db (name &key (host "127.0.0.1") (port 5984) (prototype =database=))
  "Creates a new CouchDB database. Returns a database object that can be used to operate on it."
  (let ((db (create prototype 'host host 'port port 'name name)))
    (handle-request response (db-request db :method :put)
      (:created db)
      (:internal-server-error (error "Illegal database name: ~A" name))
      (:precondition-failed (error 'db-already-exists :uri (db-namestring db))))))

(defun ensure-db (name &rest all-keys)
  "Either connects to an existing database, or creates a new one.
 Returns two values: If a new database was created, (DB-OBJECT T) is returned. Otherwise, (DB-OBJECT NIL)"
  (handler-case (values (apply #'create-db name all-keys) t)
    (db-already-exists () (values (apply #'connect-to-db name all-keys) nil))))

(defmessage delete-db (db &key)
  (:documentation "Deletes a CouchDB database.")
  (:reply ((db =database=) &key)
    (handle-request response (db-request db :method :delete)
      (:ok response)
      (:not-found (error 'db-not-found :uri (db-namestring db))))))

(defmessage compact-db (db)
  (:documentation "Triggers a database compaction.")
  (:reply ((db =database=))
    (handle-request response (db-request db :uri "_compact" :method :post)
      (:accepted response))))

;;;
;;; Documents
;;;
(defmessage get-document (db id)
  (:documentation "Returns an CouchDB document from DB as an alist.")
  (:reply ((db =database=) id)
    (handle-request response (db-request db :uri id)
      (:ok response)
      (:not-found (error 'document-not-found :db db :id id)))))

(defmessage all-documents (db &key)
  (:documentation "Returns all CouchDB documents in DB, in alist form.")
  (:reply ((db =database=) &key startkey endkey limit include-docs)
    (let (params)
      (when startkey (push `("startkey" . ,(prin1-to-string startkey)) params))
      (when endkey (push `("endkey" . ,(prin1-to-string endkey)) params))
      (when limit (push `("limit" . ,(prin1-to-string limit)) params))
      (when include-docs (push `("include_docs" . "true") params))
      (handle-request response (db-request db :uri "_all_docs" :parameters params)
        (:ok response)))))

(defmessage batch-get-documents (db &rest doc-ids)
  (:documentation "Uses _all_docs to quickly fetch the given DOC-IDs in a single request.")
  (:reply ((db =database=) &rest doc-ids)
    (handle-request response
        (db-request db :uri "_all_docs"
                    :parameters '(("include_docs" . "true"))
                    :method :post
                    :content (format nil "{\"foo\":[~{~S~^,~}]}" doc-ids))
      (:ok response))))

(defmessage put-document (db id doc &key)
  (:documentation "Puts a new document into DB, using ID.")
  (:reply ((db =database=) id doc &key batch-ok-p)
    (handle-request response
        (db-request db :uri id :method :put
                    :external-format-out +utf-8+
                    :content doc
                    :parameters (when batch-ok-p '(("batch" . "ok"))))
      ((:created :accepted) response)
      (:conflict (error 'document-conflict :id id :doc doc)))))

(defmessage delete-document (db id revision)
  (:documentation "Deletes an existing document.")
  (:reply ((db =database=) id revision)
    (handle-request response (db-request db :uri (format nil "~A?rev=~A" id revision) :method :delete)
      (:ok response))))

(defmessage copy-document (db from-id to-id &key)
  (:documentation "Copies a document's content in-database.")
  (:reply ((db =database=) from-id to-id &key revision)
    (handle-request response
        (db-request db :uri from-id :method :copy
                    :additional-headers `(("Destination" . ,to-id))
                    :parameters `(,(when revision `("rev" . ,revision))))
      (:created response))))
