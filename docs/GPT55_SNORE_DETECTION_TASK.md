# Zadanie pre GPT-5.5: oprava detekcie chrápania v SnoreAlert

Tento dokument je samostatné implementačné zadanie. Najskôr prečítaj platné AGENTS.md a existujúci projekt, potom vykonaj implementáciu, testy a zdokumentuj výsledky. Nezostaň pri návrhu alebo úprave jedného prahu. Zachovaj existujúci vzhľad aplikácie a fungujúci spôsob zostavenia IPA.

## 1. Cieľ a obmedzenia

Používateľ má iPhone 14, aktuálny iOS a Garmin Forerunner 965. Večer ručne zapne počúvanie a zamkne displej. Aplikácia lokálne rozpozná opakované chrápanie, po potvrdení epizódy odošle tichú iOS notifikáciu a opakuje ju, kým epizóda trvá. Garmin má pri doručení vibrovať bez zvuku. Krátka pauza medzi nádychmi nesmie epizódu ukončiť. Po skončení chrápania sa odosielanie zastaví aj vtedy, keď pokračuje reč, šušťanie alebo iný hluk.

Používateľ má iba Windows 11. Zostavenie pre iOS už funguje cez GitHub Actions a inštalácia cez Sideloadly. Nevyžaduj vlastný Mac, platený server, App Store ani predplatné. macOS testy môžu bežať cez existujúci cloudový workflow; testovací import M4A do iPhonu nesmie vyžadovať Xcode. Súkromné nahrávky neposielaj na server, necommituj ich a automaticky ich nepridávaj do CI. Súčasný .gitignore ich vylučuje.

Pravidelnosť nie je sama osebe dôkaz chrápania. Implementuj kombináciu akustického rozpoznania typu zvuku, časového priebehu a stavového automatu. Nesmieš sľúbiť spoľahlivosť, ktorú nemáš nameranú.

## 2. Zistenia z existujúceho kódu

Relevantné súbory:

- `SnoreAlert/SnoreAlert/Detection/SnoreDetector.swift`
- `SnoreAlert/SnoreAlert/Audio/SnoreAudioMonitor.swift`
- `SnoreAlert/SnoreAlert/Notifications/NotificationRepeater.swift`
- `SnoreAlert/SnoreAlert/Models/AppSettings.swift`
- `SnoreAlert/SnoreAlert/ContentView.swift`
- `SnoreAlert/SnoreAlert/Resources/Info.plist`
- `.github/workflows/build-ios-unsigned.yml`

Konkrétne problémy, ktoré treba opraviť:

1. Súčasná `confidence` je vážená kombinácia hlasitosti, niekoľkých frekvenčných výkonov a penalizácie prudkej zmeny. Nie je to pravdepodobnosť chrápania. Reč a pohyb môžu splniť tieto podmienky.
2. `bandEnergy` sčíta izolované Goertzelove frekvencie s odlišnými rozostupmi. Nejde o integrovanú energiu celého pásma. Výsledok závisí od toho, či úzka harmonická trafí skúšanú frekvenciu. Prípadné pásmové príznaky počítaj cez vhodne okenkované FFT/PSD alebo filtre, so správnou normalizáciou.
3. `rhythmicBreathingScore` povoľuje dva impulzy. Pri jedinom intervale 3,8 s vyjde skóre `0,45 × 1/3 + 0,35 × 1 + 0,20 × 1 = 0,70`, teda nad prahom 0,62. Dva náhodné zvuky preto môžu potvrdiť „rytmus“. Vetva `hasStrongSnoring` má ešte nižší prah rytmu 0,45.
4. Intervaly mimo rozsahu sa vyfiltrujú pred výpočtom konzistencie. Nepravidelná sekvencia tak môže vyzerať pravidelne. Zlé intervaly musia znižovať podporu alebo začať novú kandidátsku sekvenciu.
5. `positiveWindows` počíta buffery, nie dychy. Niekoľko bufferov jedného zvuku nesmie predstavovať viac nádychov.
6. `Date()` meria čas spracovania namiesto pozície zvuku. Zmena času, fronta práce a rýchly replay nahrávky menia správanie detektora.
7. `analysis.isSnoring` môže zostať pravdivé na základe starej histórie. Monitor tým znovu nastavuje `lastSnoringAt`, hoci nepribudol nový chrápavý dych. Až potom ešte čaká `stopDelay`. To predlžuje notifikácie po skončení zvuku.
8. Výpočty bežia priamo v audio tap callbacku. `stop()` resetuje detektor mimo tohto toku a staré callbacky môžu aktualizovať UI alebo obnoviť alarm. Chýba dôsledná serializácia a identita relácie.
9. Chýba riadenie prerušení audia, zmien vstupnej trasy a výpadkov výsledkov. Pri strate mikrofónu nesmie pokračovať alarm založený na starej detekcii.
10. `NotificationRepeater` ruší timer, ale nekontroluje platnosť už rozbehnutej odosielacej práce ani chyby `center.add`. Tichá notifikácia nie je potvrdením vibrácie hodiniek.
11. Vyššia „Citlivosť“ dnes znamená vyšší prah, teda menej detekcií. Zaveď zrozumiteľné mapovanie a migráciu už uložených nastavení; zmena defaultov neprepíše existujúce UserDefaults.

## 3. Dostupné vzorky a už namerané údaje

Analýza vykonaná 12. 9. 2026 lokálne; originály zostali nezmenené:

| Súbor | Formát | Trvanie | Medián RMS v 8192-vzorkových blokoch |
| --- | --- | --- | --- |
| `samples/snoring_positive/snorring.m4a` | AAC, 48 kHz, stereo | 523,499 s | −58,386 dBFS |
| `samples/non_snoring_negative/no-snorring.m4a` | AAC, 48 kHz, stereo | 272,981 s | −52,337 dBFS |

Meranie RMS bolo po dekódovaní a štandardnom mono downmixe. Nejde o kalibrované dB SPL ani o hlasitosť samotných označených dychov. Medián celej pozitívnej nahrávky je približne o 6 dB nižší. Pevný absolútny hlasitostný prah preto nie je vhodný hlavný rozlišovač.

Orientačné meranie rytmu: Butterworthov pásmový filter 4. rádu 80–2000 Hz, RMS obálka po 20 ms, 30-sekundové úseky, orezanie obálky na 95. percentile, odčítanie priemeru a normalizovaná autokorelácia. Hľadalo sa maximum v oneskoreniach 1,4–8,5 s. Pozitívna vzorka má napríklad dominantné oneskorenia 4,82 s v úseku 0–30 s, 5,02 s v 30–60 s, 4,78 s v 240–270 s a 4,40 s v 480–510 s. To podporuje použitie rytmu približne 4–5 s, ale nedokazuje typ zvuku ani pravidelnosť celej nahrávky.

V negatívnej vzorke často vyhrala priamo dolná hranica 1,4 s, nie samostatný periodický vrchol. Samotná výška maxima autokorelácie teda nestačí: pomalá zmena hlasitosti môže tiež dať vysoké skóre. Vyžaduj významný lokálny vrchol, porovnanie s okolím a podporu z oddelených impulzov. Neprispôsobuj detektor jedinému tempu 4–5 s.

Orientačný Python replay existujúcich pravidiel pri defaultoch 0,72 / 7 s našiel v negatívnej vzorke štyri alarmové intervaly približne 42,15–51,37; 103,77–121,34; 161,28–175,62; 245,25–272,98 s. Kandidátskych bufferov bolo 7,50 % v negatívnej a 3,26 % v pozitívnej vzorke. Ide o diagnostickú aproximáciu: mono downmix namiesto prvého stereo kanála, vzorkový čas a matematicky ekvivalentné Fourierove projekcie vo Float64 namiesto Swift Goertzel vo Float. Nie je to vykonanie iOS aplikácie ani meranie recall. Pred/po porovnanie musíš urobiť skutočným Swift detektorom v spoločnom replay rozhraní.

Názov priečinka označuje súbor, nie každú milisekundu jeho obsahu. Pred meraním presnosti vytvor časové anotácie dychov a epizód. Neoznač automaticky ticho a pohyb v pozitívnom súbore za chrápanie. Ak nedokážeš obsah posluchovo overiť, vytvor nástroj na označenie úsekov a výslovne označ výsledky ako neoverené. V tomto audite neboli vytvorené posluchovo potvrdené anotácie.

## 4. Odporúčaná architektúra

Prvý experiment vykonaj s Apple SoundAnalysis: `SNClassifySoundRequest(classifierIdentifier: .version1)` a `SNAudioStreamAnalyzer`. Over v `knownClassifications`, či klasifikátor na cieľovom OS poskytuje identifikátor chrápania (očakávané `snoring`) a relevantné kategórie reči/dýchania. Nevymýšľaj identifikátory. Ak chrápanie chýba alebo klasifikátor zlyhá, zobraz diagnostiku a zdokumentuj potrebu iného modelu; neprepni potichu na detekciu ľubovoľného rytmu.

Najskôr zmeraj výstupy vstavaného modelu na vzorkách cez lokálny testovací import do aplikácie, prípadne dostupný macOS. Tento model na Windows nespustíš. Nepredpokladaj, že použitie ML automaticky vyrieši chyby. Až ak meranie ukáže nedostatočnosť, navrhni ďalšie dáta alebo konkrétny overiteľný postup pre vlastný Core ML klasifikátor; netrénuj univerzálny model od nuly z dvoch súborov.

Začni približne 1-sekundovým klasifikačným oknom a 50 % prekrytím, ale rešpektuj `windowDurationConstraint` a zmeraj aj vhodné alternatívy. Používaj `SNClassificationResult.timeRange`, nie čas príchodu callbacku. Skóre kategórií vstavaného modelu sú nezávislé, nesčítavajú sa na 1: nerob z nich softmax ani podmienku „snoring musí byť vyššie než speech“. Každá kategória má vlastný kalibrovaný prah. Reč môže zvýšiť požadovanú podporu pre chrápanie; tvrdé veto reči môže potlačiť skutočné chrápanie pri súbehu zvukov. Otestuj tento konflikt.

Oddeľ moduly aspoň logicky:

1. Audio vstup a bezpečné odovzdanie PCM s časovou pozíciou.
2. Akustické príznaky a klasifikácia typu zvuku.
3. Segmentácia samostatných dychových impulzov a odhad rytmu.
4. Stavový automat epizódy.
5. Odosielanie notifikácií podľa aktuálneho stavu.

## 5. Impulzy, šum a rytmus

- Krátke rámce približne 20–40 ms používaj na obálku a segmentáciu, nie ako samostatné klasifikované dychy. Ak používaš FFT príznaky, aplikuj Hannovo okno a korektné energetické pomery.
- Odhaduj priebežné pozadie robustným nízkym percentilom a používaj pomer signálu k pozadiu. Počas kandidáta/epizódy nedovoľ rýchle vytiahnutie pozadia na úroveň chrápania. Ošetri štart počas chrápania; nevyžaduj úvodné absolútne ticho.
- Klasifikáciu zarovnaj s obálkou podľa audio času. Prekryté klasifikačné okná nesmú vytvárať duplicitné dychy ani prekryť pauzy tak, že všetko splynie do jedného impulzu. Ak sú výsledky oneskorené, uchovaj ohraničenú históriu obálky a rozhoduj až po ich zarovnaní.
- Segmentuj nábeh, trvanie a koniec impulzu hysterézou. Krátke vnútorné poklesy môžeš zlúčiť, ale zachovaj pauzy medzi dychmi. Over dĺžky kandidátov; orientačný rozsah 0,25–2,5 s slúži iba na začiatok ladenia, nie ako neoverený zákaz ostatných dychov.
- Jeden hrubý nádych môže obsahovať veľa špičiek a nádych/výdych dva zvuky. Deduplikuj ich a testuj dvojnásobnú/polovičnú frekvenciu; nerob z jednej udalosti viac dôkazov.
- Pred vstupom do epizódy vyžaduj aspoň tri samostatné akusticky podporené chrápavé impulzy a aspoň dva po sebe idúce prijateľné intervaly. Žiadna „strong“ vetva nesmie obísť požadovaný počet dychov.
- Počiatočný rozsah periódy môže byť 1,5–8,5 s. Presné hranice a toleranciu variability nastav podľa dát. Toleruj mierne nepravidelné dýchanie, nevyžaduj metronóm. Použi robustný odhad periódy a relatívnu odchýlku intervalov.
- História má pokrývať aj tri pomalé dychy, napríklad 30 s. Zlé intervaly nezahadzuj tak, aby umelo vylepšovali skóre. Izolované alebo staré zvuky nesmú potvrdiť novú epizódu.
- Autokorelácia odšumenej obálky môže byť podporný signál. Pravidelnosť bez akustickej podpory chrápania nikdy nestačí: otestuj pravidelnú reč, klepanie a cyklický mechanický hluk.

## 6. Stavový automat a presný koniec epizódy

Zaveď explicitné stavy `idle`, `candidate`, `snoring`, `interrupted`. Rozlišuj nové potvrdenie konkrétneho dychu od pretrvávajúceho stavu epizódy. Detektor nech vracia napríklad identitu dychu, jeho začiatok/koniec, periódu, stav a dôvod prechodu.

Pri treťom potvrdenom dychu prejde `candidate` do `snoring` a vyšle prvú notifikáciu. Pri perióde 4–5 s to prirodzene znamená približne 8–10 s od prvého dychu plus jeho trvanie a oneskorenie klasifikácie. Tento kompromis vysvetli; neznižuj počet dôkazov len kvôli okamžitému alarmu.

`lastConfirmedSnoreEnd` aktualizuj iba novým akusticky potvrdeným impulzom, nie každý callback, nie každý pozitívny prekrytý výsledok a nie hodnotou `isSnoring == true`. Počas epizódy nepravidelný, ale jasný nový chrápavý dych môže obnoviť čas; hluk a samotný historický rytmus ho obnoviť nesmú.

Pauza medzi dychmi udrží stav. Počiatočný návrh tolerancie je `clamp(max(userStopDelay, 1.8 * estimatedPeriod), 7, 15)` sekúnd od konca posledného potvrdeného dychu; pred platným odhadom použi definovaný konzervatívny default. Je to návrh na overenie, nie nameraný optimálny parameter. Zabezpeč, aby UI jasne uvádzalo efektívnu toleranciu, ak ju adaptívny režim mení.

Pre spracovanie signálu používaj vzorkový čas (`sampleTime / sampleRate`) alebo injektovaný audio clock. `Date` používaj len pre zobrazenie času udalosti. Pre bezpečnostný timeout neprichádzajúceho audia používaj nezávislý monotónny čas. Pri zastavení audio času nesmie zostať alarm visieť navždy.

Pri Stop, prerušení audia, chybe klasifikátora alebo dlhšom výpadku čerstvých dát zastav opakovanie, zneplatni reláciu a ukonči/označ epizódu. Už doručenú vibráciu nie je možné odvolať. Po obnove začni s novou históriou; staré callbacky nesmú opäť spustiť alarm.

## 7. Audio na pozadí a vlákna

Zachovaj background audio a oprávnenie k mikrofónu. Vstup má byť mikrofón iPhonu; neprepínaj sa nepozorovane na HFP mikrofón slúchadiel. Zaznamenaj použitú trasu a jej zmeny. Over správnu kategóriu a režim `AVAudioSession` na zariadení.

Audio callback nech vykonáva iba nevyhnutné kopírovanie do vlastneného bufferu z ohraničeného poolu/fronty. Nedrž neplatný ukazovateľ na PCM a nezavádzaj dlhé zámky, FFT, klasifikáciu, logovanie na disk alebo publikovanie UI v real-time callbacku. Pri preťažení nevytváraj neobmedzený backlog; zaznamenaj medzeru a resetuj dotknutú časovú históriu.

Analyzér a detektor serializuj na jednej fronte/aktore, UI aktualizuj na MainActor s obmedzenou frekvenciou. Nastavenia odovzdávaj konzistentným snapshotom. Pri route change vytvor analyzér pre nový formát. Ošetri audio interruption, media-services reset a viacnásobný Start/Stop. Všetky oneskorené práce viaž na session ID/generation token.

## 8. Notifikácie a Garmin

Použi existujúce lokálne notifikácie s `content.sound = nil`. Bežná iOS notifikácia neposkytuje aplikácii priamy príkaz na vibračný motor Garminu. Zrkadlenie a vibráciu riadia iOS a nastavenia hodiniek. Žiadny odhad „odoslané“ neoznačuj ako „hodinky zavibrovali“.

Po potvrdení epizódy odošli jednu notifikáciu a opakuj podľa používateľovho intervalu (existujúci default 3 s zachovaj do testu). Zachovaj unikátne identifikátory požiadaviek a identitu epizódy. Timer je iba mechanizmus prebudenia: pred každým odoslaním znovu over aktívnu reláciu, aktuálnu epizódu a čerstvosť detekcie. Pri oneskorení neposielaj spätne všetky zmeškané notifikácie.

Serializuj spustenie, zastavenie a odosielanie. Stop zneplatní aj čakajúcu prácu a odstráni prípadné ešte čakajúce požiadavky patriace tejto aplikácii/epizóde. Zachytávaj úspech prijatia požiadavky iOS alebo chybu `add`; nejde o potvrdenie doručenia na hodinky. Neplánuj dopredu dlhú sériu a nepoužívaj opakovaný systémový time-interval trigger pre trojsekundový interval.

Na fyzickom zariadení oddeľ test klasifikácie, stavového automatu, vytvorenia notifikácie v iOS a vibrácie Garminu. Over zamknutý iPhone, Notification Center, nastavenia náhľadov podľa aktuálneho návodu Garmin, povolené smart notifications, vibrácie zapnuté, tóny vypnuté a DND vypnuté aj v spánkovom režime. Focus na iPhone nesmie blokovať SnoreAlert. Ak krátke intervaly systém zlučuje alebo potláča, nameraj to a uveď obmedzenie; nesľubuj jeho obídenie.

## 9. Replay, anotácie a kalibrácia

Vytvor diagnostický import lokálneho M4A cez výber súboru v iPhone. Doplň ho diskrétne, bez redizajnu bežnej obrazovky. Offline replay nesmie sám odosielať reálne notifikácie. Používa rovnakú segmentáciu, klasifikáciu a stavový automat ako mikrofón, ale injektovaný čas a falošný notification sink. Pre analýzu súboru možno využiť SNAudioFileAnalyzer; pri porovnávaní zabezpeč totožný formát a časové zarovnanie, prednostne spoločnú PCM stream cestu.

Vráť časovú os s RMS dBFS, pozadím, klasifikačnými skóre, impulzmi, periódou, prechodmi stavov, dôvodmi zamietnutia a plánovanými odoslaniami. Exportuj CSV/JSON lokálne na výslovný pokyn. Nahrávku štandardne neukladaj počas celej noci. Neobmedzené RAM logy ani stovky UI udalostí za sekundu nie sú prípustné.

Vytvor anotácie v samostatnom súbore: zdroj, začiatok, koniec, trieda, epizóda, istota anotácie a skupina zdrojovej nahrávky. Zoznam tried minimálne chrápanie, reč, pohyb/posteľ, bežné dýchanie, ticho a neisté. Neisté úseky neprezentuj ako pravdu.

Porovnaj pôvodný a nový detektor na tých istých úsekoch. Prahy dolaďuj na kalibračných blokoch a vyhodnoť oddelené súvislé bloky s medzerou aspoň dĺžky celej histórie detektora. Nedávaj prekrývajúce sa okná ani augmentácie rovnakého úseku do oboch skupín. Dve nahrávky z jednej situácie nestačia na dôkaz presnosti počas rôznych nocí; pridať nezávislú noc je potrebné na overenie zovšeobecnenia.

Meraj detekciu epizód, oneskorenie prvého alarmu, oneskorenie zastavenia a počet falošných epizód za hodinu negatívnych dát. Súborová klasifikácia „v nahrávke je chrápanie“ nestačí. Definuj, ako sa predikovaná epizóda páruje s anotovanou, a zvlášť reportuj rozdelenie jednej epizódy na viac alarmov. Nulu chýb za 4,55 minúty negatívnej vzorky neprezentuj ako dôkaz nuly chýb za celú noc.

## 10. Akceptačné testy

Tieto hodnoty sú ciele implementácie, nie už dosiahnuté výsledky:

- Žiadny vstup do `snoring` po jednom ani dvoch izolovaných impulzoch. Žiadny vstup pri pravidelnom ne-chrápavom klepaní, reči alebo ventilátore bez akustickej podpory chrápania.
- Cieľ aspoň 90 % detegovaných posluchovo potvrdených epizód s minimálne troma dychmi na oddelenom teste. Uveď počet epizód a presnú definíciu; pri malom počte neuvádzaj percento bez menovateľa.
- Cieľ nula falošných alarmových epizód v poskytnutej negatívnej nahrávke. Pre dlhší test cieliť najviac jednu falošnú epizódu za 8 hodín; bez dostatku negatívnych hodín tento cieľ zostáva neoverený.
- Prvý alarm do konca tretieho vyhovujúceho impulzu plus zmeraná latencia klasifikácie/spracovania; počiatočný cieľ najviac 2 s dodatočného oneskorenia pri 1-sekundovom okne. Reportuj skutočný výsledok.
- Pravidelné dychy 4–5 s držia jednu epizódu aj cez tiché pauzy. Testuj tiež pomalšie, rýchlejšie a mierne nepravidelné dychy a zvuk pri nádychu aj výdychu.
- Po poslednom potvrdenom dychu sa nevytvárajú nové požiadavky za hranicou efektívneho timeoutu plus zmeraná latencia spracovania. Reč a pohyb po chrápaní timeout neobnovujú.
- Pri Stop alebo prerušení nevzniká nová odosielacia práca; oneskorený výsledok starej relácie alarm neobnoví. Watchdog zastaví opakovanie pri chýbajúcom audio toku aj bez nových callbackov.
- Deterministický replay pri rôznych veľkostiach vstupných bufferov a rýchlostiach spracovania dá rovnaké prechody v rámci deklarovaného časového rozlíšenia. Otestuj 44,1/48 kHz a mono/stereo so správnym resamplingom.
- Regresie: tichšie/hlasnejšie vzorky (napr. ±6 a −12 dB bez clippingu), ticho, štart priamo počas chrápania, jeden dlhý zvuk, nepravidelné impulzy, výpadok dát, oneskorené alebo duplicitné výsledky, prepnutie trasy, Stop/Start a zmena systémového času. Syntetické testy overujú logiku; nenahrádzajú skutočné negatívne nahrávky.
- Na iPhone 14 minimálne 30 minút so zamknutým displejom a následne celonočný test: stabilita audio toku, teplota, spotreba batérie, rast pamäte a správanie pri prerušení. CPU/pamäť musia zostať ohraničené.
- Osobitný test reálnych opakovaných vibrácií na Garmin Forerunner 965 aj po automatickom začiatku Sleep Mode. Výsledok tohto testu neodvodzuj z logov aplikácie.

## 11. Požadované odovzdanie

Odovzdaj upravený Swift kód, zapojenie všetkých nových súborov do Xcode projektu, primerané testy, funkčný diagnostický replay a migrované nastavenia. Zachovaj build a sideload postup pre Windows. Do docs zapíš architektúru, zvolené parametre s dôvodmi, výsledky pred/po a návod na testovanie na telefóne.

Na Windows spusti dostupné testy prenositeľnej logiky; Apple frameworky over na skutočne dostupnom macOS/iOS prostredí. Ak ich nemáš, implementuj spustiteľný testovací postup a presne odlíš pripravené testy od vykonaných. CI nesmie predstierať test vzoriek, ktoré sú kvôli .gitignore iba lokálne.

Záver musí obsahovať: čo bolo opravené, aké merania to podporujú, ktoré testy boli vykonané, ktoré zostávajú na iPhone/Garmine a čo nie je overené. Samotný úspešný build nie je dôkazom kvalitnej detekcie.

## Technické zdroje

- [Apple: Sound Analysis](https://developer.apple.com/documentation/soundanalysis) — systémové rozpoznávanie zvuku a možnosť vlastného modelu.
- [Apple: Classifying Sounds in an Audio Stream](https://developer.apple.com/documentation/soundanalysis/classifying-sounds-in-an-audio-stream) — PCM, sampleTime, samostatná analytická fronta a nový analyzér pri zmene formátu.
- [Apple: Discover built-in sound classification in SoundAnalysis](https://developer.apple.com/videos/play/wwdc2021/10036/) — knownClassifications, trvanie okien, časové intervaly výsledkov a nezávislé skóre tried. Parametre a pravidlá epizód uvedené vyššie sú návrhom tohto zadania, nie odporúčaním Apple.
- [Garmin Forerunner 965: Managing Notifications](https://www8.garmin.com/manuals/webhelp/GUID-0221611A-992D-495E-8DED-1DD448F7A066/EN-US/GUID-5A95D297-7177-4745-ADAF-AC4855E0B7FA.html) — na iPhone sa výber zrkadlených notifikácií riadi nastaveniami iOS.
- [Garmin: nastavenie notifikácií](https://support.garmin.com/en-AU/?faq=TLeDN92ZU0AgN4df6HakwA) — požadované nastavenia notifikácií na pripojenom telefóne.
- [Garmin Forerunner 965: Controls](https://www8.garmin.com/manuals/webhelp/GUID-0221611A-992D-495E-8DED-1DD448F7A066/EN-GB/GUID-700E76C4-F7E2-4984-8199-D59D6A31DFB9.html) — Do Not Disturb vypína upozornenia a notifikácie.
