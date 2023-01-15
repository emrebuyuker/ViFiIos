//
//  FacultyViewController.swift
//  ViFi
//
//  Created by Emre Büyüker on 15.01.2023.
//

import UIKit
import Firebase
import FirebaseDatabase

class FacultyViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    var uniName = String()
    var facultiesNameArray = [String]()
    
    @IBOutlet weak var facultyTableView: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.facultyTableView.delegate = self
        self.facultyTableView.dataSource = self

        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
    }
    
    override func viewWillAppear(_ animated: Bool) {
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        
        facultiesNameArray.removeAll()
        
        getDataFromFireBase()
    }
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        
        dataBaseRefence.child("Universitiess").child(uniName).observe(DataEventType.childAdded) { (snapshot) in
            if (snapshot.key != "uniname" ) {
                self.facultiesNameArray.append(snapshot.key)
            }
            self.facultyTableView.reloadData()
        }
    }
    
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.facultiesNameArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = facultyTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! FacultyTableViewCell
        cell.facultyNameLabel.text = facultiesNameArray[indexPath.row]
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let facName = facultiesNameArray[indexPath.row]
        let tabBar = tabBarController as! BaseTabbarVC
        tabBar.facNameVariable = facName
        self.tabBarController?.selectedIndex = 2
    }
}
