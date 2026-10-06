export type Lang = "en" | "ko";

type Item = { title: string; body: string };

export interface Copy {
  htmlLang: string;
  nav: { features: string; cleanup: string; install: string };
  switchTo: string;
  hero: { eyebrow: string; titleA: string; titleB: string; lede: string; shotAlt: string };
  download: {
    label: string;
    requirements: string[];
    unknownSize: string;
  };
  features: { eyebrow: string; title: string; intro: string; items: Item[] };
  cleanup: {
    eyebrow: string;
    title: string;
    intro: string;
    checks: Item[];
    table: { head: [string, string, string]; rows: [string, string, string][]; optional: string };
    shotAlt: string;
    note: string;
  };
  privacy: Item[];
  install: { eyebrow: string; title: string; steps: Item[]; note: string };
  final: string;
  footer: string;
}

const en: Copy = {
  htmlLang: "en",
  nav: { features: "Features", cleanup: "Smart cleanup", install: "Install" },
  switchTo: "한국어",
  hero: {
    eyebrow: "A little space. A little clarity.",
    titleA: "See where your Mac's space went,",
    titleB: "at a glance.",
    lede: "AppleTree maps how much room your folders and files take up. Find the big files worth removing, and clear old caches and logs within limits you set.",
    shotAlt: "AppleTree main window: shortcuts on the left, 119 GB analyzed with Movies as the largest folder, and a ring chart of folder sizes.",
  },
  download: {
    label: "Download for Mac",
    requirements: ["macOS 14 or later", "Apple Silicon"],
    unknownSize: "dmg",
  },
  features: {
    eyebrow: "Features",
    title: "Find it, see it, clean it up",
    intro: "AppleTree reads file sizes and dates, never file contents. Hidden files and the insides of app packages are counted too.",
    items: [
      { title: "Space map", body: "Switch between a ring chart and a block map. Area is size, so heavy folders stand out. Click a slice to step inside that folder." },
      { title: "Largest files", body: "Every file under the current folder, sorted by size, with its modified date, so big files you haven't touched in months are easy to spot." },
      { title: "Name, extension and regex search", body: "Search by name, filter by a list of extensions such as mov, mp4, or use a regular expression for precise matches." },
      { title: "Save matches as a zip", body: "Bundle just the files your search found into one archive. Handy for keeping a copy before you delete." },
      { title: "Act right from the list", body: "Open, show in Finder, copy the path or move to Trash. Moving to Trash asks first, then redraws the map." },
      { title: "Fast rescans", body: "Results are remembered, so the next launch opens instantly. Cancel a scan and your previous results stay put." },
    ],
  },
  cleanup: {
    eyebrow: "Smart cleanup",
    title: "One button, only as far as you allow",
    intro: "Set the scope once. After that, press Smart cleanup and AppleTree shows each folder it checks and each file it removes as it goes.",
    checks: [
      { title: "Leaves what you're using alone.", body: "Caches of running apps, open files and recently changed files are skipped." },
      { title: "Always protects important data.", body: "Documents, original downloads, keys, AI models, databases, Git repositories and folders you protect are never touched." },
      { title: "Checks again right before deleting.", body: "If a file changed in the meantime, it stays. No administrator password is ever requested." },
      { title: "Keeps a record.", body: "See before-and-after size per category and the real change in free space. The history button beside Smart cleanup reopens your last 10 runs." },
    ],
    table: {
      head: ["What", "Where", "Default rule"],
      rows: [
        ["App caches", "~/Library/Caches", "unchanged for 7+ days"],
        ["Logs and crash reports", "~/Library/Logs", "older than 30 days"],
        ["Developer tool caches", "npm · pip · Yarn · Go", "unchanged for 7+ days"],
      ],
      optional: "(optional)",
    },
    shotAlt: "Cleanup complete: 2.5 MB removed, free space up 2.5 MB, with before and after bars for app caches and logs.",
    note: "Cleaned files are deleted directly, not moved to Trash. Apps rebuild caches when they need them, so an app may open a little slower the first time afterwards. If the helper tool used to find cleanup candidates isn't installed, AppleTree shows how to install it.",
  },
  privacy: [
    { title: "Nothing leaves your Mac", body: "All analysis happens locally. No account and no internet connection needed." },
    { title: "Contents stay unread", body: "AppleTree looks at size, date and type only. It never opens your documents or photos." },
    { title: "English and Korean", body: "Follows your Mac's language, or pick one in AppleTree's settings." },
  ],
  install: {
    eyebrow: "Install",
    title: "Download, then drag to Applications",
    steps: [
      { title: "Download the dmg and open it.", body: "Double-click AppleTree.dmg in Downloads. A window opens with AppleTree and an Applications folder." },
      { title: "Drag AppleTree onto Applications.", body: "Then eject the AppleTree disk in Finder. You can delete the dmg afterward." },
      { title: "Allow it the first time you open it.", body: "AppleTree isn't notarized by Apple yet, so macOS warns on first launch. Go to System Settings → Privacy & Security and click Open Anyway." },
      { title: "Turn on Full Disk Access if you need it.", body: "To include protected folders, enable AppleTree in System Settings → Privacy & Security → Full Disk Access, then reopen the app." },
    ],
    note: "Requires macOS 14 Sonoma or later on an Apple Silicon (M1 or newer) Mac. Sizes are the sum of logical file sizes, so APFS clones and compressed files can make them differ slightly from actual disk usage.",
  },
  final: "Start with your own Mac.",
  footer: "AppleTree · Room to breathe.",
};

const ko: Copy = {
  htmlLang: "ko",
  nav: { features: "기능", cleanup: "알아서 정리", install: "설치" },
  switchTo: "English",
  hero: {
    eyebrow: "A little space. A little clarity.",
    titleA: "내 Mac의 공간이 어디로 갔는지,",
    titleB: "한눈에.",
    lede: "AppleTree는 폴더와 파일이 차지하는 용량을 지도로 보여주는 Mac 앱입니다. 큰 파일을 찾아 정리하고, 오래된 캐시와 로그는 정해 둔 범위 안에서 안전하게 비웁니다.",
    shotAlt: "AppleTree 메인 화면. 왼쪽에 바로가기, 위쪽에 분석한 용량 119 GB와 가장 큰 폴더 Movies, 아래에 폴더별 용량을 보여주는 원형 지도.",
  },
  download: {
    label: "Mac용 다운로드",
    requirements: ["macOS 14 이상", "Apple Silicon"],
    unknownSize: "dmg",
  },
  features: {
    eyebrow: "기능",
    title: "찾고, 보고, 정리하기까지",
    intro: "파일 내용을 읽지 않고 크기와 날짜 같은 정보만으로 분석합니다. 숨김 파일과 앱 패키지 안쪽까지 빠짐없이 셉니다.",
    items: [
      { title: "용량 지도", body: "원형 지도와 사각형 지도 중에서 고를 수 있습니다. 넓이가 곧 용량이라 무거운 폴더가 바로 보이고, 조각을 누르면 그 폴더 안으로 들어갑니다." },
      { title: "큰 파일 목록", body: "지금 보고 있는 폴더 아래의 모든 파일을 크기순으로 나열합니다. 수정일도 함께 보여서 오래 안 쓴 대용량 파일을 쉽게 고를 수 있습니다." },
      { title: "이름·확장자·정규식 검색", body: "이름으로 찾거나 mov, mp4처럼 확장자 목록으로 거를 수 있습니다. 더 정교하게 찾고 싶으면 정규식도 씁니다." },
      { title: "찾은 파일을 zip으로", body: "검색으로 걸러낸 파일만 골라 압축 파일 하나로 저장합니다. 지우기 전에 따로 보관해 두고 싶을 때 씁니다." },
      { title: "목록에서 바로 작업", body: "열기, Finder에서 보기, 경로 복사, 휴지통으로 이동을 목록에서 바로 합니다. 휴지통 이동은 한 번 더 확인한 뒤 실행하고 지도를 다시 그립니다." },
      { title: "빠른 재분석", body: "한 번 분석한 결과를 기억해 두어 다음 실행에서 바로 보여줍니다. 분석 중에 취소해도 이전 결과는 그대로 남습니다." },
    ],
  },
  cleanup: {
    eyebrow: "알아서 정리",
    title: "버튼 하나로, 정해 둔 범위만큼만",
    intro: "처음 한 번 범위를 정하면, 다음부터는 알아서 정리 버튼만 누르면 됩니다. 진행하는 동안 지금 어떤 폴더를 살피고 어떤 파일을 지우는지 화면에 보여줍니다.",
    checks: [
      { title: "쓰고 있는 건 건드리지 않습니다.", body: "실행 중인 앱의 캐시, 열려 있는 파일, 최근에 바뀐 파일은 건너뜁니다." },
      { title: "중요한 데이터는 늘 보호합니다.", body: "문서, 다운로드 원본, 키, AI 모델, 데이터베이스, Git 저장소, 직접 지정한 보호 폴더는 대상에서 빠집니다." },
      { title: "지우기 직전에 한 번 더 확인합니다.", body: "파일이 그사이 바뀌었으면 지우지 않습니다. 관리자 권한도 요구하지 않습니다." },
      { title: "결과와 기록이 남습니다.", body: "범주별 정리 전후 용량과 실제 늘어난 여유 공간을 보여줍니다. 버튼 옆 기록 아이콘으로 최근 10번의 정리를 다시 볼 수 있습니다." },
    ],
    table: {
      head: ["정리 대상", "위치", "기본 기준"],
      rows: [
        ["앱 캐시", "~/Library/Caches", "7일 이상 미변경"],
        ["로그·오류 보고서", "~/Library/Logs", "30일 이상"],
        ["개발 도구 캐시", "npm · pip · Yarn · Go", "7일 이상 미변경"],
      ],
      optional: "(선택)",
    },
    shotAlt: "정리 완료 화면. 정리한 파일 2.5 MB, 여유 공간 +2.5 MB, 앱 캐시와 로그의 정리 전후 막대 그래프.",
    note: "정리 대상 파일은 휴지통을 거치지 않고 바로 지웁니다. 캐시는 앱이 필요할 때 다시 만들기 때문에, 처음 한 번은 앱이 조금 느리게 열릴 수 있습니다. 정리 후보를 찾을 때 쓰는 보조 도구가 없으면 앱이 설치 방법을 안내합니다.",
  },
  privacy: [
    { title: "서버로 보내지 않습니다", body: "모든 분석은 내 Mac 안에서 끝납니다. 계정도, 인터넷 연결도 필요 없습니다." },
    { title: "파일 내용을 읽지 않습니다", body: "크기, 날짜, 종류 같은 정보만 봅니다. 문서나 사진의 내용은 열어보지 않습니다." },
    { title: "한국어와 영어", body: "Mac의 언어 설정을 따르고, 앱 설정에서 언어를 따로 바꿀 수도 있습니다." },
  ],
  install: {
    eyebrow: "설치",
    title: "내려받아서 응용 프로그램 폴더로",
    steps: [
      { title: "dmg 파일을 내려받아 엽니다.", body: "다운로드 폴더에서 AppleTree.dmg를 더블 클릭하면 AppleTree와 응용 프로그램 폴더가 있는 창이 열립니다." },
      { title: "AppleTree를 응용 프로그램 폴더로 끌어다 놓습니다.", body: "복사가 끝나면 Finder에서 AppleTree 디스크를 추출하세요. dmg 파일은 지워도 됩니다." },
      { title: "처음 열 때 한 번 허용합니다.", body: "아직 Apple 공증을 받지 않은 앱이라 첫 실행 때 경고가 뜹니다. 시스템 설정 → 개인정보 보호 및 보안에서 아래쪽의 ‘그래도 열기’를 누르세요." },
      { title: "필요하면 전체 디스크 접근을 켭니다.", body: "보호된 폴더까지 분석하려면 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한에서 AppleTree를 켜고 앱을 다시 실행합니다." },
    ],
    note: "macOS 14 Sonoma 이상, Apple Silicon(M1 이후) Mac에서 실행됩니다. 용량은 파일의 논리적 크기를 더한 값이라, APFS 복제나 압축 파일 때문에 실제 디스크 점유량과 조금 다를 수 있습니다.",
  },
  final: "내 Mac부터 살펴보세요.",
  footer: "AppleTree · 조금 더 가벼운 Mac.",
};

export const copy: Record<Lang, Copy> = { en, ko };
