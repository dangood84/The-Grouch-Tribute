unit ugrouchtrash;

{$mode objfpc}{$H+}

{ Count items in a trash folder. Hosts watch this directory (FSEvents on
  macOS, a 0.5 s poll everywhere) and call TrashWasEmptied when the count
  drops from something to nothing — the modern stand-in for the classic
  Mac OS Special → Empty Trash Apple Event. }

interface

function DefaultTrashDir: string;
function CountTrashItems(const Dir: string): Integer;
function TrashWasEmptied(PrevCount, NewCount: Integer): Boolean;
function IsEmptyTrashTitle(const Title: string): Boolean;

implementation

uses
  SysUtils;

function DefaultTrashDir: string;
begin
{$IFDEF DARWIN}
  Result := IncludeTrailingPathDelimiter(GetUserDir) + '.Trash';
{$ELSE}
  {$IFDEF WINDOWS}
  { Recycle Bin is not a plain folder; hosts use SHQueryRecycleBin.
    This path is only for tests and for a manual "watch this dir" fallback. }
  Result := IncludeTrailingPathDelimiter(GetUserDir) + '$Recycle.Bin';
  {$ELSE}
  Result := IncludeTrailingPathDelimiter(GetUserDir) +
    '.local' + PathDelim + 'share' + PathDelim + 'Trash' + PathDelim + 'files';
  {$ENDIF}
{$ENDIF}
end;

function CountTrashItems(const Dir: string): Integer;
var
  Search: TSearchRec;
  Code: Integer;
  Name: string;
begin
  Result := 0;
  if (Dir = '') or (not DirectoryExists(Dir)) then
    Exit;
  Code := FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, Search);
  try
    while Code = 0 do
    begin
      Name := Search.Name;
      { Finder / Explorer / Nautilus bookkeeping is not "trash". }
      if (Name <> '.') and (Name <> '..') and
         (Name <> '.DS_Store') and (Name <> 'desktop.ini') and
         (Name <> '.localized') then
        Inc(Result);
      Code := FindNext(Search);
    end;
  finally
    FindClose(Search);
  end;
end;

function TrashWasEmptied(PrevCount, NewCount: Integer): Boolean;
begin
  { State change the hosts care about: there *was* junk, and now the
    bin is empty. 0→0 (already empty) and 3→2 (one file restored) are
    not Empty Trash. }
  Result := (PrevCount > 0) and (NewCount = 0);
end;

function IsEmptyTrashTitle(const Title: string): Boolean;
var
  T: string;
begin
  { Finder menu item, including the ellipsis variants and a few
    localisations. Used by the optional Accessibility observer. }
  T := LowerCase(Trim(Title));
  T := StringReplace(T, '…', '', [rfReplaceAll]);
  T := StringReplace(T, '...', '', [rfReplaceAll]);
  T := Trim(T);
  Result :=
    (T = 'empty trash') or
    (T = 'empty wastebasket') or
    (T = 'empty bin') or
    (T = 'empty the bin') or
    (T = 'papierkorb leeren') or
    (T = 'den papierkorb leeren') or
    (T = 'vider la corbeille') or
    (T = 'vaciar la papelera') or
    (T = 'svuota il cestino') or
    (Pos('empty trash', T) > 0) or
    (Pos('empty wastebasket', T) > 0) or
    (Pos('empty bin', T) > 0);
end;

end.
