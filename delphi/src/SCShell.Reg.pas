{ ============================================================================
  SCShell.Reg — Design-time registration.
  ============================================================================ }
unit SCShell.Reg;

interface

procedure Register;

implementation

uses
  System.Classes,
  SCShell.Ctrl;

procedure Register;
begin
  RegisterComponents('SCShell', [TSCRataShell]);
end;

end.
