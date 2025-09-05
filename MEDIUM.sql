-- create database Rugved;

-- use Rugved;

CREATE TABLE Patients (
    PatientID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100) NOT NULL,
    DOB DATE NOT NULL,
    Gender ENUM('Male', 'Female', 'Other'),
    ContactInfo VARCHAR(255)
);

CREATE TABLE Doctors (
    DoctorID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100) NOT NULL,
    Specialty VARCHAR(100)
);

CREATE TABLE DoctorAvailableSlots (
    SlotID INT PRIMARY KEY AUTO_INCREMENT,
    DoctorID INT NOT NULL,
    SlotTime DATETIME NOT NULL,
    IsBooked BOOLEAN DEFAULT FALSE,
    FOREIGN KEY (DoctorID) REFERENCES Doctors(DoctorID)
);

CREATE TABLE Appointments (
    AppointmentID INT PRIMARY KEY AUTO_INCREMENT,
    PatientID INT NOT NULL,
    DoctorID INT NOT NULL,
    AppointmentDate DATETIME NOT NULL,
    Status ENUM('Scheduled', 'Completed', 'Cancelled'),
    FOREIGN KEY (PatientID) REFERENCES Patients(PatientID),
    FOREIGN KEY (DoctorID) REFERENCES Doctors(DoctorID)
);

CREATE TABLE TreatmentTypes (
    TreatmentTypeID INT PRIMARY KEY AUTO_INCREMENT,
    TreatmentName VARCHAR(100) UNIQUE NOT NULL,
    StandardCost DECIMAL(10,2) NOT NULL
);

CREATE TABLE Treatments (
    TreatmentID INT PRIMARY KEY AUTO_INCREMENT,
    AppointmentID INT NOT NULL,
    TreatmentTypeID INT NOT NULL,
    Cost DECIMAL(10,2) NOT NULL,
    Notes TEXT,
    FOREIGN KEY (AppointmentID) REFERENCES Appointments(AppointmentID),
    FOREIGN KEY (TreatmentTypeID) REFERENCES TreatmentTypes(TreatmentTypeID)
);

CREATE TABLE Billing (
    BillID INT PRIMARY KEY AUTO_INCREMENT,
    PatientID INT NOT NULL,
    TotalAmount DECIMAL(10,2) NOT NULL,
    PaymentStatus ENUM('Paid', 'Unpaid', 'Pending'),
    FOREIGN KEY (PatientID) REFERENCES Patients(PatientID)
);


-- PROCEDURES
-- Checks doctor availability. Inserts into Appointments. Returns confirmation or error.

DELIMITER //
CREATE PROCEDURE BookAppointment (
    IN in_PatientID INT,
    IN in_DoctorID INT,
    IN in_AppointmentDate DATETIME
)
BEGIN
    DECLARE availableSlotID INT;

    SELECT SlotID INTO availableSlotID
    FROM DoctorAvailableSlots
    WHERE DoctorID = in_DoctorID
      AND SlotTime = in_AppointmentDate
      AND IsBooked = FALSE
    LIMIT 1;

    IF availableSlotID IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No available slot for the doctor at the specified time.';
    ELSE
        UPDATE DoctorAvailableSlots
        SET IsBooked = TRUE
        WHERE SlotID = availableSlotID;

        INSERT INTO Appointments (PatientID, DoctorID, AppointmentDate, Status)
        VALUES (in_PatientID, in_DoctorID, in_AppointmentDate, 'Scheduled');

        SELECT 'Appointment successfully booked.' AS Message;
    END IF;
END //

DELIMITER ;

-- GenerateBill(PatientID): Calculates total treatment cost for a patient. Inserts into Billing.
DELIMITER //

CREATE PROCEDURE GenerateBill (
    IN in_PatientID INT
)
BEGIN
    DECLARE totalAmount DECIMAL(10,2);

    SELECT IFNULL(SUM(t.Cost), 0) INTO totalAmount
    FROM Treatments t
    JOIN Appointments a ON t.AppointmentID = a.AppointmentID
    WHERE a.PatientID = in_PatientID;

    INSERT INTO Billing (PatientID, TotalAmount, PaymentStatus)
    VALUES (in_PatientID, totalAmount, 'Pending');

    SELECT CONCAT('Bill generated with total amount: ₹', totalAmount) AS Message;
END //

DELIMITER ;


-- FOR TRIGGERS

ALTER TABLE Appointments
ADD COLUMN SlotID INT;

ALTER TABLE Appointments
ADD FOREIGN KEY (SlotID) REFERENCES DoctorAvailableSlots(SlotID);




-- TRIGGERS

-- After inserting into Appointments, decrement AvailableSlots for the doctor.
DELIMITER $$

CREATE TRIGGER trg_AfterAppointmentInsert
AFTER INSERT ON Appointments
FOR EACH ROW
BEGIN
    UPDATE DoctorAvailableSlots
    SET IsBooked = TRUE
    WHERE SlotID = NEW.SlotID;
END $$

DELIMITER ;


-- After inserting into Treatments, update the corresponding Billing record
DELIMITER $$

CREATE TRIGGER trg_AfterTreatmentInsert
AFTER INSERT ON Treatments
FOR EACH ROW
BEGIN
    DECLARE patient_id INT;
    DECLARE total DECIMAL(10,2);

    -- Find patient from appointment
    SELECT PatientID INTO patient_id
    FROM Appointments
    WHERE AppointmentID = NEW.AppointmentID;

    -- Calculate new total cost of all treatments for patient
    SELECT IFNULL(SUM(t.Cost), 0) INTO total
    FROM Treatments t
    JOIN Appointments a ON t.AppointmentID = a.AppointmentID
    WHERE a.PatientID = patient_id;

    -- Update Billing record with new total amount
    UPDATE Billing
    SET TotalAmount = total
    WHERE PatientID = patient_id;
END $$

DELIMITER ;


-- TRANSACTIONS
-- Wrap appointment booking and treatment assignment in a transaction: If any step fails (e.g., doctor unavailable), rollback.

DELIMITER $$

CREATE PROCEDURE BookAppointmentWithTreatment (
    IN in_PatientID INT,
    IN in_DoctorID INT,
    IN in_AppointmentDate DATETIME,
    IN in_TreatmentTypeID INT,
    IN in_Cost DECIMAL(10,2),
    IN in_Notes TEXT
)
BEGIN
    DECLARE availableSlotID INT;
    DECLARE newAppointmentID INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Transaction failed. Changes have been rolled back.';
    END;

    START TRANSACTION;

    -- Check for available slot
    SELECT SlotID INTO availableSlotID
    FROM DoctorAvailableSlots
    WHERE DoctorID = in_DoctorID
      AND SlotTime = in_AppointmentDate
      AND IsBooked = FALSE
    LIMIT 1;

    IF availableSlotID IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No available slot for the doctor at the specified time.';
    END IF;

    -- Mark slot as booked
    UPDATE DoctorAvailableSlots
    SET IsBooked = TRUE
    WHERE SlotID = availableSlotID;

    -- Create appointment
    INSERT INTO Appointments (PatientID, DoctorID, AppointmentDate, Status, SlotID)
    VALUES (in_PatientID, in_DoctorID, in_AppointmentDate, 'Scheduled', availableSlotID);

    SET newAppointmentID = LAST_INSERT_ID();

    -- Insert treatment
    INSERT INTO Treatments (AppointmentID, TreatmentTypeID, Cost, Notes)
    VALUES (newAppointmentID, in_TreatmentTypeID, in_Cost, in_Notes);

    COMMIT;

    SELECT 'Appointment and treatment successfully booked.' AS Message;
END $$

DELIMITER ;


-- JOINS

-- Query to list all appointments with patient and doctor details.

SELECT 
    a.AppointmentID,
    p.Name AS PatientName,
    d.Name AS DoctorName,
    d.Specialty,
    a.AppointmentDate,
    a.Status
FROM Appointments a
JOIN Patients p ON a.PatientID = p.PatientID
JOIN Doctors d ON a.DoctorID = d.DoctorID;

-- Query to show total billing per patient.
SELECT 
    p.PatientID,
    p.Name AS PatientName,
    IFNULL(SUM(b.TotalAmount), 0) AS TotalBilling
FROM Patients p
LEFT JOIN Billing b ON p.PatientID = b.PatientID
GROUP BY p.PatientID, p.Name;


-- Query to list treatments given by a specific doctor.
SELECT 
    d.Name AS DoctorName,
    p.Name AS PatientName,
    a.AppointmentDate,
    tt.TreatmentName,
    t.Cost,
    t.Notes
FROM Treatments t
JOIN TreatmentTypes tt ON t.TreatmentTypeID = tt.TreatmentTypeID
JOIN Appointments a ON t.AppointmentID = a.AppointmentID
JOIN Patients p ON a.PatientID = p.PatientID
JOIN Doctors d ON a.DoctorID = d.DoctorID
WHERE d.DoctorID = 1; 





-- EXECUTION
INSERT INTO Patients (Name, DOB, Gender, ContactInfo)
VALUES
    ('Ravi Sharma', '1990-05-12', 'Male', 'ravi.sharma@example.com'),
    ('Anita Mehta', '1985-08-20', 'Female', 'anita.mehta@example.com'),
    ('Karan Joshi', '2000-11-30', 'Male', 'karan.joshi@example.com');
    
    
    
    
INSERT INTO Doctors (Name, Specialty)
VALUES
    ('Dr. Seema Patil', 'Cardiology'),
    ('Dr. Arjun Verma', 'Dermatology'),
    ('Dr. Neha Desai', 'General Medicine');

INSERT INTO DoctorAvailableSlots (DoctorID, SlotTime)
VALUES
    (1, '2025-09-06 10:00:00'),
    (1, '2025-09-06 11:00:00'),
    (2, '2025-09-06 12:00:00'),
    (3, '2025-09-06 14:00:00');


INSERT INTO TreatmentTypes (TreatmentName, StandardCost)
VALUES
    ('ECG', 500.00),
    ('Skin Biopsy', 1500.00),
    ('General Check-up', 300.00);



CALL BookAppointmentWithTreatment(
    1, -- PatientID (Ravi Sharma)
    1, -- DoctorID (Dr. Seema Patil)
    '2025-09-06 10:00:00', -- SlotTime (must match available slot)
    1, -- TreatmentTypeID (ECG)
    500.00,
    'Routine ECG checkup'
);


CALL GenerateBill(1); 


CALL BookAppointment(
    2, -- PatientID
    1, -- DoctorID
    '2025-09-06 11:00:00' 
);

CALL GenerateBill(2);



select * from Appointments;
select * from Billing;
select * from DoctorAvailableSlots;
select * from Doctors;
select * from Patients;
select * from Treatments;
select * from TreatmentTypes;



