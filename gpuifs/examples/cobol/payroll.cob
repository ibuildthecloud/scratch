      *> payroll.cob: weekly payroll for a small firm, in COBOL.
      *>
      *>   gpuifs --headless --dir ALPINE:#L cobc -x payroll.cob
      *>   gpuifs -t Payroll --dir ALPINE:#L \
      *>       --env COB_LS_VALIDATE=false ./payroll
      *>
      *> GnuCOBOL builds a Linux program, so it runs in the h9 machine
      *> on an Alpine root (ALPINE is a tree with gnucobol installed),
      *> where the gpuifs tree is /9 followed by $gpuifs. COBOL does all
      *> the file work itself, through ordinary SELECT ... ASSIGN files
      *> whose names are set at run time: it makes the window, writes
      *> the screen as a tree document, reads the events file one
      *> record (one event) at a time, reads each input's value file,
      *> and writes field errors, the pay stub and the register back as
      *> files. A CLOSE is what makes gpuifs apply a whole file, and
      *> begin/commit on the window's ctl make each run one frame.
      *>
      *> COB_LS_VALIDATE=false: GnuCOBOL 3.2 refuses control characters
      *> in LINE SEQUENTIAL records by default, as COBOL 2022 says, and
      *> the register table and the pay stub are tab-separated.
      *>
      *> Money is fixed-point decimal, as COBOL has always done it:
      *> PIC 9(7)V99 fields, COMPUTE ROUNDED, and edited pictures like
      *> $$$,$$$,$$9.99 for display. Time over 40 hours is paid at
      *> time and a half. The tax table is made up.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. PAYROLL.

       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT EVENTS ASSIGN TO EVENTS-PATH
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS EVENTS-STATUS.
           SELECT GUI ASSIGN TO GUI-PATH
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS GUI-STATUS.
           SELECT GUI-IN ASSIGN TO GUI-PATH
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS GUI-IN-STATUS.

       DATA DIVISION.
       FILE SECTION.
       FD  EVENTS.
       01  EVENT-REC               PIC X(1024).
       FD  GUI.
       01  GUI-REC                 PIC X(1024).
       FD  GUI-IN.
       01  GUI-IN-REC              PIC X(1024).

       WORKING-STORAGE SECTION.
       01  BASE                    PIC X(200).
       01  REL                     PIC X(200).
       01  EVENTS-PATH             PIC X(256).
       01  GUI-PATH                PIC X(256).
       01  EVENTS-STATUS           PIC XX.
       01  GUI-STATUS              PIC XX.
       01  GUI-IN-STATUS           PIC XX.
       01  LN                      PIC X(1024).
       01  TAB                     PIC X VALUE X"09".
       01  EV                      PIC X(1024).
       01  EV-NAME                 PIC X(32).
       01  HITS                    PIC 9(4).
       01  DONE-FLAG               PIC X VALUE "N".
           88  DONE                VALUE "Y".
       01  VAL                     PIC X(200).

      *> One run: what was typed, and what it comes to.
       01  EMP-NAME                PIC X(40).
       01  HOURS                   PIC 9(3)V99.
       01  RATE                    PIC 9(4)V99.
       01  REG-HRS                 PIC 9(3)V99.
       01  OT-HRS                  PIC 9(3)V99.
       01  REG-PAY                 PIC 9(7)V99.
       01  OT-PAY                  PIC 9(7)V99.
       01  GROSS                   PIC 9(7)V99.
       01  FED                     PIC 9(7)V99.
       01  FICA                    PIC 9(7)V99.
       01  NET                     PIC 9(7)V99.
       01  OK-FLAG                 PIC X.
           88  ALL-OK              VALUE "Y".

      *> The register: every stub run this session, as display text.
       01  REG-COUNT               PIC 99 VALUE 0.
       01  REGISTER.
           05  REG-LINE OCCURS 99 TIMES.
               10  R-NAME          PIC X(40).
               10  R-HOURS         PIC X(10).
               10  R-RATE          PIC X(12).
               10  R-GROSS         PIC X(16).
               10  R-TAX           PIC X(16).
               10  R-NET           PIC X(16).
       01  I                       PIC 99.
       01  TOTAL-GROSS             PIC 9(9)V99 VALUE 0.
       01  TOTAL-NET               PIC 9(9)V99 VALUE 0.

      *> Edited pictures: COBOL's number formatting.
       01  MONEY                   PIC $$$,$$$,$$9.99.
       01  BIG-MONEY               PIC $$$,$$$,$$$,$$9.99.
       01  HRS-ED                  PIC ZZ9.99.
       01  N-ED                    PIC Z9.

       PROCEDURE DIVISION.
       MAIN.
           ACCEPT BASE FROM ENVIRONMENT "gpuifs"
           IF BASE = SPACES
               MOVE "/mnt/gpui" TO BASE
           END-IF
      *>   A Linux program sees the 9front tree under /9.
           STRING "/9" FUNCTION TRIM(BASE) DELIMITED BY SIZE
               INTO REL
           MOVE REL TO BASE
           PERFORM BUILD-SCREEN
           MOVE SPACES TO EVENTS-PATH
           STRING FUNCTION TRIM(BASE) "/events" DELIMITED BY SIZE
               INTO EVENTS-PATH
           OPEN INPUT EVENTS
           PERFORM UNTIL DONE
               READ EVENTS INTO EV
                   AT END SET DONE TO TRUE
                   NOT AT END PERFORM HANDLE-EVENT
               END-READ
           END-PERFORM
           CLOSE EVENTS
           STOP RUN.

       HANDLE-EVENT.
           MOVE SPACES TO EV-NAME
           UNSTRING EV DELIMITED BY SPACE INTO EV-NAME
           MOVE 0 TO HITS
           INSPECT EV TALLYING HITS FOR ALL " tag=run "
           EVALUATE TRUE
               WHEN (EV-NAME = "click" OR EV-NAME = "submit")
                       AND HITS > 0
                   PERFORM RUN-PAYROLL
               WHEN EV-NAME = "action"
                   INSPECT EV TALLYING HITS FOR ALL " id=run "
                   IF HITS > 0
                       PERFORM RUN-PAYROLL
                   END-IF
               WHEN EV-NAME = "close" OR EV-NAME = "quit"
                   SET DONE TO TRUE
           END-EVALUATE.

      *> ---- The screen -------------------------------------------
       BUILD-SCREEN.
           MOVE "/ctl" TO REL
           PERFORM OPEN-GUI
           MOVE "window main title=Payroll size=820,600 min=640,480"
               TO LN
           PERFORM SAY
           CLOSE GUI
           MOVE "/keymap" TO REL
           PERFORM OPEN-GUI
           MOVE "cmd-enter run" TO LN
           PERFORM SAY
           CLOSE GUI
           MOVE "/windows/main/root/tree" TO REL
           PERFORM OPEN-GUI
           STRING "div root  style='v_flex size_full p=20 gap=14 "
               "bg=background'"
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE "  div head  style='h_flex items_baseline gap=10'"
               TO LN
           PERFORM SAY
           STRING "    text h  text='ACME Widget Co.'  "
               "style='text_xl font_semibold'"
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           STRING "    text sub  "
               "text='Weekly payroll, computed in COBOL'  "
               "style='text_sm text_color=muted_foreground'"
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE "  form f  layout=h  tag=run" TO LN
           PERFORM SAY
           MOVE "    field name  label=Employee" TO LN
           PERFORM SAY
           MOVE "      input in  placeholder='Grace Hopper'" TO LN
           PERFORM SAY
           MOVE "    field hours  label=Hours" TO LN
           PERFORM SAY
           MOVE "      input in  placeholder=40" TO LN
           PERFORM SAY
           MOVE "    field rate  label='Rate per hour'" TO LN
           PERFORM SAY
           MOVE "      input in  placeholder=25.00" TO LN
           PERFORM SAY
           MOVE "    field go  label=' '" TO LN
           PERFORM SAY
           STRING "      button run  label='Run payroll'  style=primary"
               "  tag=run" DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE "  div body  style='h_flex flex_1 gap=14 items_stretch'"
               TO LN
           PERFORM SAY
           MOVE "    div left  style='v_flex gap=8 w=300'" TO LN
           PERFORM SAY
           MOVE "      text t1  text='Pay stub'  style='font_semibold'"
               TO LN
           PERFORM SAY
           MOVE "      description-list stub  columns=1  bordered=on"
               TO LN
           PERFORM SAY
           MOVE "    div right  style='v_flex flex_1 gap=8'" TO LN
           PERFORM SAY
           MOVE "      text t2  text=Register  style='font_semibold'"
               TO LN
           PERFORM SAY
           MOVE "      table reg  stripe=on  style=flex_1" TO LN
           PERFORM SAY
           STRING "      text total  style='text_sm text_right "
               "text_color=muted_foreground'  "
               "text='No one paid yet.'"
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           CLOSE GUI

           MOVE "/windows/main/root/body/right/reg/columns" TO REL
           PERFORM OPEN-GUI
           STRING "emp" TAB "Employee" TAB "170" INTO LN
           PERFORM SAY
           STRING "hrs" TAB "Hours" TAB "70" TAB "align=right" INTO LN
           PERFORM SAY
           STRING "rate" TAB "Rate" TAB "80" TAB "align=right" INTO LN
           PERFORM SAY
           STRING "net" TAB "Net pay" TAB "110" TAB "align=right"
               INTO LN
           PERFORM SAY
           CLOSE GUI
           MOVE "/windows/main/root/body/left/stub/items" TO REL
           PERFORM OPEN-GUI
           STRING "Employee" TAB "-" INTO LN
           PERFORM SAY
           CLOSE GUI
           MOVE "/windows/main/focus" TO REL
           PERFORM OPEN-GUI
           MOVE "root/f/name/in" TO LN
           PERFORM SAY
           CLOSE GUI.

      *> ---- One run ----------------------------------------------
       RUN-PAYROLL.
           MOVE "/windows/main/ctl" TO REL
           PERFORM OPEN-GUI
           MOVE "begin" TO LN
           PERFORM SAY
           CLOSE GUI
           SET ALL-OK TO TRUE

           MOVE "/windows/main/root/f/name/in/value" TO REL
           PERFORM READ-VALUE
           MOVE VAL TO EMP-NAME
           MOVE "/windows/main/root/f/name/error" TO REL
           IF EMP-NAME = SPACES
               MOVE "Who are we paying?" TO LN
           END-IF
           PERFORM PUT-ERROR

           MOVE "/windows/main/root/f/hours/in/value" TO REL
           PERFORM READ-VALUE
           MOVE "/windows/main/root/f/hours/error" TO REL
           IF FUNCTION TEST-NUMVAL(VAL) NOT = 0 OR VAL = SPACES
               MOVE "Hours must be a number" TO LN
           ELSE
               IF FUNCTION NUMVAL(VAL) > 168
                       OR FUNCTION NUMVAL(VAL) <= 0
                   MOVE "There are 168 hours in a week" TO LN
               ELSE
                   COMPUTE HOURS ROUNDED = FUNCTION NUMVAL(VAL)
               END-IF
           END-IF
           PERFORM PUT-ERROR

           MOVE "/windows/main/root/f/rate/in/value" TO REL
           PERFORM READ-VALUE
           MOVE "/windows/main/root/f/rate/error" TO REL
           IF FUNCTION TEST-NUMVAL-C(VAL) NOT = 0 OR VAL = SPACES
               MOVE "Rate must be an amount" TO LN
           ELSE
               IF FUNCTION NUMVAL-C(VAL) > 9999.99
                       OR FUNCTION NUMVAL-C(VAL) <= 0
                   MOVE "Rate must be 0.01 to 9,999.99" TO LN
               ELSE
                   COMPUTE RATE ROUNDED = FUNCTION NUMVAL-C(VAL)
               END-IF
           END-IF
           PERFORM PUT-ERROR

           IF ALL-OK
               PERFORM COMPUTE-PAY
               PERFORM SHOW-STUB
               PERFORM ADD-TO-REGISTER
               PERFORM CLEAR-INPUTS
           END-IF

           MOVE "/windows/main/ctl" TO REL
           PERFORM OPEN-GUI
           MOVE "commit" TO LN
           PERFORM SAY
           CLOSE GUI.

       COMPUTE-PAY.
           IF HOURS > 40
               MOVE 40 TO REG-HRS
               COMPUTE OT-HRS = HOURS - 40
           ELSE
               MOVE HOURS TO REG-HRS
               MOVE 0 TO OT-HRS
           END-IF
           COMPUTE REG-PAY ROUNDED = REG-HRS * RATE
           COMPUTE OT-PAY ROUNDED = OT-HRS * RATE * 1.5
           COMPUTE GROSS = REG-PAY + OT-PAY
      *>   10% of the first $500 a week, 22% of the rest.
           IF GROSS > 500
               COMPUTE FED ROUNDED = 50 + (GROSS - 500) * 0.22
           ELSE
               COMPUTE FED ROUNDED = GROSS * 0.10
           END-IF
           COMPUTE FICA ROUNDED = GROSS * 0.0765
           COMPUTE NET = GROSS - FED - FICA.

       SHOW-STUB.
           MOVE "/windows/main/root/body/left/stub/items" TO REL
           PERFORM OPEN-GUI
           STRING "Employee" TAB FUNCTION TRIM(EMP-NAME)
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE REG-HRS TO HRS-ED
           MOVE REG-PAY TO MONEY
           STRING "Regular, " FUNCTION TRIM(HRS-ED) " h" TAB
               FUNCTION TRIM(MONEY) DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE OT-HRS TO HRS-ED
           MOVE OT-PAY TO MONEY
           STRING "Overtime, " FUNCTION TRIM(HRS-ED) " h at 1.5" TAB
               FUNCTION TRIM(MONEY) DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE GROSS TO MONEY
           STRING "Gross pay" TAB FUNCTION TRIM(MONEY)
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE FED TO MONEY
           STRING "Federal tax" TAB "-" FUNCTION TRIM(MONEY)
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE FICA TO MONEY
           STRING "FICA, 7.65%" TAB "-" FUNCTION TRIM(MONEY)
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE NET TO MONEY
           STRING "Net pay" TAB FUNCTION TRIM(MONEY)
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           CLOSE GUI.

       ADD-TO-REGISTER.
           IF REG-COUNT < 99
               ADD 1 TO REG-COUNT
           END-IF
           MOVE EMP-NAME TO R-NAME(REG-COUNT)
           MOVE HOURS TO HRS-ED
           MOVE FUNCTION TRIM(HRS-ED) TO R-HOURS(REG-COUNT)
           MOVE RATE TO MONEY
           MOVE FUNCTION TRIM(MONEY) TO R-RATE(REG-COUNT)
           MOVE NET TO MONEY
           MOVE FUNCTION TRIM(MONEY) TO R-NET(REG-COUNT)
           ADD GROSS TO TOTAL-GROSS
           ADD NET TO TOTAL-NET

           MOVE "/windows/main/root/body/right/reg/rows" TO REL
           PERFORM OPEN-GUI
           PERFORM VARYING I FROM 1 BY 1 UNTIL I > REG-COUNT
               MOVE I TO N-ED
               STRING "r" FUNCTION TRIM(N-ED) TAB
                   FUNCTION TRIM(R-NAME(I)) TAB
                   FUNCTION TRIM(R-HOURS(I)) TAB
                   FUNCTION TRIM(R-RATE(I)) TAB
                   FUNCTION TRIM(R-NET(I))
                   DELIMITED BY SIZE INTO LN
               PERFORM SAY
           END-PERFORM
           CLOSE GUI

           MOVE "/windows/main/root/body/right/total/text" TO REL
           PERFORM OPEN-GUI
           MOVE REG-COUNT TO N-ED
           MOVE TOTAL-GROSS TO BIG-MONEY
           STRING FUNCTION TRIM(N-ED) " paid. Gross "
               FUNCTION TRIM(BIG-MONEY) DELIMITED BY SIZE INTO LN
           MOVE TOTAL-NET TO BIG-MONEY
           MOVE SPACES TO VAL
           STRING FUNCTION TRIM(LN) ", net "
               FUNCTION TRIM(BIG-MONEY) "." DELIMITED BY SIZE INTO VAL
           MOVE VAL TO LN
           PERFORM SAY
           CLOSE GUI.

       CLEAR-INPUTS.
      *>   Opening a value file for output and closing it empties it.
           MOVE "/windows/main/root/f/name/in/value" TO REL
           PERFORM OPEN-GUI
           CLOSE GUI
           MOVE "/windows/main/root/f/hours/in/value" TO REL
           PERFORM OPEN-GUI
           CLOSE GUI
           MOVE "/windows/main/root/f/rate/in/value" TO REL
           PERFORM OPEN-GUI
           CLOSE GUI
           MOVE "/windows/main/focus" TO REL
           PERFORM OPEN-GUI
           MOVE "root/f/name/in" TO LN
           PERFORM SAY
           CLOSE GUI.

      *> ---- File helpers ------------------------------------------
      *> OPEN-GUI: open BASE followed by REL for output.
       OPEN-GUI.
           MOVE SPACES TO GUI-PATH
           STRING FUNCTION TRIM(BASE) FUNCTION TRIM(REL)
               DELIMITED BY SIZE INTO GUI-PATH
           OPEN OUTPUT GUI
           MOVE SPACES TO LN.

      *> SAY: write LN as one line of the open file.
       SAY.
           WRITE GUI-REC FROM LN
           MOVE SPACES TO LN.

      *> READ-VALUE: the first line of BASE followed by REL, into VAL.
       READ-VALUE.
           MOVE SPACES TO GUI-PATH VAL
           STRING FUNCTION TRIM(BASE) FUNCTION TRIM(REL)
               DELIMITED BY SIZE INTO GUI-PATH
           OPEN INPUT GUI-IN
           IF GUI-IN-STATUS = "00"
               READ GUI-IN INTO VAL
                   AT END CONTINUE
               END-READ
               CLOSE GUI-IN
           END-IF.

      *> PUT-ERROR: set a field's error to LN; spaces clear it.
       PUT-ERROR.
           IF LN NOT = SPACES
               MOVE "N" TO OK-FLAG
           END-IF
           MOVE SPACES TO GUI-PATH
           STRING FUNCTION TRIM(BASE) FUNCTION TRIM(REL)
               DELIMITED BY SIZE INTO GUI-PATH
           OPEN OUTPUT GUI
           IF LN NOT = SPACES
               WRITE GUI-REC FROM LN
           END-IF
           CLOSE GUI
           MOVE SPACES TO LN.
