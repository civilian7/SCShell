{ ============================================================================
  02_menu_driven/MenuDriven.dpr — 메뉴/상태바로 모든 기능을 노출하는 풀 데모.
  메뉴: File / Edit / View / VI / Search / Tools
  상태바: PID / CWD / 상태 / 모드 플래그 / VI 활성 / 종료 코드
  ============================================================================ }
program MenuDriven;

uses
  Vcl.Forms,
  MenuMain in 'MenuMain.pas' {FormMain};

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'SCShell — Menu Driven Demo';
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
